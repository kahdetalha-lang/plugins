# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'zlib'
require 'openssl'
require 'base64'
require 'securerandom'
require 'uri'

module KahDetalha
  module CentralKPilot
    # Atualização automática dos plugins comprados.
    #
    # Fluxo: checagem leve 1x por dia (só versões) -> download para uma pasta de trabalho ->
    # validação (assinatura do servidor, SHA-256, zip, produto, versão, compatibilidade) ->
    # extração para "staging" -> troca completa num momento seguro (ao fechar o SketchUp, ou ao
    # abrir, antes de o plugin carregar) -> confirmação na abertura seguinte -> remoção do backup.
    #
    # Cada troca é registrada num diário (journal) com todos os movimentos planejados. Se o
    # SketchUp fechar no meio, a próxima abertura desfaz o que foi feito e tenta de novo depois.
    # Nada aqui depende de licença: falhar ao atualizar nunca bloqueia um plugin licenciado.
    module Updater
      CHECK_INTERVAL = 24 * 60 * 60
      MANUAL_MIN_INTERVAL = 10 * 60
      DELAY_RANGE = (30..150).freeze
      CONFIRM_DELAY = 45
      API_TIMEOUT = 15
      DOWNLOAD_TIMEOUT = 120
      MAX_PACKAGE_BYTES = 100 * 1024 * 1024
      MAX_ENTRIES = 3000
      MAX_UNPACKED_BYTES = 400 * 1024 * 1024
      MAX_SWAP_ATTEMPTS = 3
      BACKUP_RETENTION = 14 * 24 * 60 * 60
      LOG_MAX_BYTES = 128 * 1024
      ALLOWED_HOST = 'flibbkyxitkvsdnmgrcl.supabase.co'
      SIGNATURE_CONTEXT = 'ck-update-v1'
      TOP_NAME_RE = /\A[A-Za-z0-9_][A-Za-z0-9_.\- ]{0,120}\z/.freeze
      VERSION_RE = /\A\d+(\.\d+){1,3}\z/.freeze

      class Abort < StandardError; end

      class << self
        attr_writer :env

        def env
          @env ||= SketchupEnv.new
        end

        # ------------------------------------------------------------------
        # Ciclo de vida
        # ------------------------------------------------------------------

        # Chamado quando a Central carrega (início do SketchUp).
        def boot!
          return if @booted

          @booted = true
          hold_session_lock
          recover_journal
          cleanup_expired
          apply_staged(before_load_only: true)
          env.on_quit { on_quit }
          env.timer(rand(DELAY_RANGE)) { run_check }
          env.timer(CONFIRM_DELAY) { confirm_swaps }
        rescue StandardError, ScriptError => error
          log("boot falhou: #{error.class}: #{error.message}")
        end

        # Ao fechar o SketchUp: aplica atualizações preparadas e reversões pendentes.
        def on_quit
          apply_staged(before_load_only: false)
          apply_reverts
        rescue StandardError, ScriptError => error
          log("on_quit falhou: #{error.class}: #{error.message}")
        ensure
          release_session_lock
        end

        # ------------------------------------------------------------------
        # Checagem
        # ------------------------------------------------------------------

        # force: abre a janela / botão Atualizar (respeita um intervalo mínimo de 10 min).
        # only: limita a alguns produtos (botão de atualizar um plugin).
        def run_check(force: false, manual: false, only: nil, &done)
          finish = lambda do |result|
            done&.call(result)
            result
          end
          return finish.call('busy') if @checking
          return finish.call('not_logged') unless env.logged_in?

          st = state
          elapsed = now - st['last_check_at'].to_i
          return finish.call('skipped') if !force && elapsed < CHECK_INTERVAL
          return finish.call('skipped') if force && !manual && elapsed < MANUAL_MIN_INTERVAL

          lock = try_lock('update')
          return finish.call('busy') unless lock

          @checking = true
          st['last_check_at'] = now
          st['last_check_result'] = 'running'
          save_state(st)

          payload = { 'sketchup_version' => env.sketchup_version.to_s, 'platform' => env.platform }
          env.api_post('updates', payload, API_TIMEOUT) do |code, body|
            begin
              result = handle_check_response(code, body, manual: manual, only: only) do |final|
                end_check(lock, final)
                finish.call(final)
              end
              if result
                end_check(lock, result)
                finish.call(result)
              end
            rescue StandardError, ScriptError => error
              log("checagem falhou: #{error.class}: #{error.message}")
              end_check(lock, 'error')
              finish.call('error')
            end
          end
          nil
        rescue StandardError, ScriptError => error
          log("checagem não iniciou: #{error.class}: #{error.message}")
          end_check(lock, 'error') if lock
          finish.call('error')
        end

        def end_check(lock, result)
          @checking = false
          st = state
          st['last_check_result'] = result
          save_state(st)
          release_lock(lock)
          log("checagem concluída: #{result}")
        end

        # Devolve o resultado na hora, ou nil quando há downloads em andamento
        # (aí chama o bloco ao terminar).
        def handle_check_response(code, body, manual:, only:, &later)
          return 'offline' if code.to_i.zero?
          return 'server_error' unless code.to_i.between?(200, 299) && body.is_a?(Hash)

          unless body['enabled'] == true
            cancel_all_staged('atualizações automáticas desligadas no servidor')
            return 'disabled'
          end

          items = Array(body['products']).select { |item| item.is_a?(Hash) && item['slug'].to_s.match?(/\A[a-z0-9_]+\z/) }
          remember_names(items)
          installed = installed_products
          queue = []
          items.each do |item|
            slug = item['slug'].to_s
            next unless installed.key?(slug)
            next if only && !only.include?(slug)

            reason = rejection_reason(item, installed[slug], manual: manual)
            if reason == :paused
              cancel_staged(slug, 'atualização suspensa no servidor')
              next
            end
            next if reason

            queue << item
          end
          return 'up_to_date' if queue.empty?

          process_queue(queue, [], &later)
          nil
        end

        def rejection_reason(item, installed_info, manual:)
          slug = item['slug'].to_s
          version = item['version'].to_s
          return :invalid unless slug.match?(/\A[a-z0-9_]+\z/) && version.match?(VERSION_RE)
          return :paused if item['paused'] == true
          return :not_newer unless newer?(version, installed_info['version'])
          return :rollout if !manual && item['rollout_included'] != true
          return :signature unless signature_valid?(item)
          return :incompatible unless compatible?(item)

          pstate = product_state(slug)
          return :failed_before if pstate.dig('failed', version) && !manual
          return :already_staged if pstate.dig('staged', 'version') == version && File.directory?(pstate.dig('staged', 'dir').to_s)
          return :already_applied if pstate.dig('swapped', 'version') == version

          nil
        end

        def process_queue(queue, results, &done)
          item = queue.shift
          unless item
            staged = results.count('staged')
            done.call(staged.positive? ? 'staged' : (results.include?('offline') ? 'offline' : 'nothing_staged'))
            return
          end

          download_and_stage(item) do |result|
            results << result
            env.timer(0) { process_queue(queue, results, &done) }
          end
        end

        # ------------------------------------------------------------------
        # Download + validação + staging
        # ------------------------------------------------------------------

        def download_and_stage(item, &done)
          slug = item['slug']
          version = item['version']
          url = item['url'].to_s
          unless allowed_url?(url)
            mark_failed(slug, version, 'endereço de download não permitido')
            return done.call('rejected')
          end

          log("baixando #{slug} #{version}")
          env.http_get(url, DOWNLOAD_TIMEOUT) do |code, bytes|
            result =
              begin
                if code.to_i.zero?
                  'offline'
                elsif !code.to_i.between?(200, 299) || bytes.nil?
                  log("download #{slug}: HTTP #{code}")
                  'download_failed'
                elsif item['size'].to_i.positive? && bytes.bytesize != item['size'].to_i
                  # Download interrompido: falha passageira, tenta de novo no próximo período.
                  log("download #{slug} incompleto (#{bytes.bytesize} de #{item['size']} bytes)")
                  'download_incomplete'
                else
                  stage_package(item, bytes)
                end
              rescue Abort => error
                log("pacote #{slug} #{version} recusado: #{error.message}")
                mark_failed(slug, version, error.message)
                'rejected'
              rescue Errno::ENOSPC
                log("sem espaço em disco para preparar #{slug} #{version}")
                set_last_result(slug, 'no_space', version, 'Sem espaço em disco para preparar a atualização.')
                'no_space'
              rescue StandardError, ScriptError => error
                log("preparação de #{slug} falhou: #{error.class}: #{error.message}")
                'error'
              end
            done.call(result)
          end
        end

        # Valida e extrai para staging. Levanta Abort quando o pacote é inválido (não tenta de novo
        # a mesma versão) e erros comuns para falhas passageiras (tenta no próximo período).
        def stage_package(item, bytes)
          slug = item['slug']
          version = item['version']
          raise Abort, 'pacote vazio ou grande demais' if bytes.bytesize.zero? || bytes.bytesize > MAX_PACKAGE_BYTES
          raise Abort, 'SHA-256 não confere (download incompleto ou alterado)' unless Digest::SHA256.hexdigest(bytes).casecmp?(item['sha256'].to_s)

          allowed = Array(item['install_paths']).map(&:to_s)
          entries = ZipReader.entries(bytes)
          validate_entries(entries, allowed, version, bytes)

          staging = File.join(work_root, 'staging', "#{slug}-#{version}")
          FileUtils.rm_rf(staging)
          FileUtils.mkdir_p(staging)
          begin
            ZipReader.extract(bytes, entries, staging)
          rescue Abort, Errno::ENOSPC
            FileUtils.rm_rf(staging)
            raise
          rescue StandardError, ScriptError => error
            FileUtils.rm_rf(staging)
            raise Abort, "falha ao extrair: #{error.class}"
          end

          tops = entries.map { |entry| entry[:name].split('/').first }.uniq.sort
          update_product(slug) do |pstate|
            old = pstate['staged']
            FileUtils.rm_rf(old['dir']) if old && old['dir'] && old['dir'] != staging
            pstate['staged'] = {
              'version' => version, 'sha256' => item['sha256'].to_s.upcase, 'dir' => staging,
              'tops' => tops, 'install_paths' => allowed, 'staged_at' => now, 'attempts' => 0
            }
            pstate['install_paths'] = allowed
            pstate['last_result'] = result_entry('staged', version, nil)
          end
          log("#{slug} #{version} preparado (#{entries.length} arquivos)")
          'staged'
        end

        def validate_entries(entries, allowed, version, bytes)
          raise Abort, 'produto sem lista de arquivos cadastrada' if allowed.empty?
          raise Abort, 'pacote sem arquivos' if entries.empty?
          raise Abort, 'pacote com arquivos demais' if entries.length > MAX_ENTRIES
          raise Abort, 'pacote grande demais descompactado' if entries.sum { |e| e[:size] } > MAX_UNPACKED_BYTES

          allowed.each { |name| raise Abort, "nome de instalação inválido: #{name}" unless TOP_NAME_RE.match?(name) }
          entries.each do |entry|
            name = entry[:name]
            raise Abort, "caminho inválido no pacote: #{name}" unless safe_relative_path?(name)

            top = name.split('/').first
            raise Abort, "arquivo fora da pasta do produto: #{name}" unless allowed.include?(top)
          end

          loaders = entries.select { |e| !e[:name].include?('/') && e[:name].downcase.end_with?('.rb') }
          raise Abort, 'carregador do plugin não encontrado' if loaders.empty?
          raise Abort, 'assinatura da Trimble (.susig) não encontrada' unless entries.any? { |e| e[:name].downcase.end_with?('.susig') }

          texts = loaders.map { |loader| ZipReader.read(bytes, loader).to_s }
          literal = /['"]#{Regexp.escape(version)}['"]/
          raise Abort, "a versão do pacote não é #{version}" unless texts.any? { |text| text.match?(literal) }
        end

        def safe_relative_path?(name)
          return false if name.empty? || name.include?("\0") || name.include?('\\')
          return false if name.start_with?('/') || name.match?(/\A[A-Za-z]:/)
          return false if name.each_char.any? { |c| c.ord < 32 }

          name.split('/', -1).none? { |part| part.empty? || part == '.' || part == '..' }
        end

        def allowed_url?(url)
          uri = URI.parse(url)
          uri.is_a?(URI::HTTPS) && uri.host == ALLOWED_HOST
        rescue StandardError
          false
        end

        def signature_valid?(item)
          sig = item['signature'].to_s
          kid = item['kid'].to_s
          pem = TokenVerify::PUBLIC_KEYS[kid]
          return false if sig.empty? || pem.nil?

          data = signing_input(item)
          OpenSSL::PKey::RSA.new(pem).verify(OpenSSL::Digest::SHA256.new, TokenVerify.b64url_decode(sig), data)
        rescue StandardError
          false
        end

        # Precisa ser idêntico ao montado pelo servidor (central-k-api, ação "updates").
        def signing_input(item)
          [
            SIGNATURE_CONTEXT, item['slug'], item['version'], item['sha256'].to_s.upcase, item['size'].to_i.to_s, item['url'],
            item['min_sketchup_version'].to_s, Array(item['platforms']).join(','), Array(item['install_paths']).join('|')
          ].join("\n")
        end

        def compatible?(item)
          min = item['min_sketchup_version'].to_s
          return false if !min.empty? && env.sketchup_major < min.to_i

          platforms = Array(item['platforms']).map(&:to_s)
          platforms.empty? || platforms.include?(env.platform)
        end

        # ------------------------------------------------------------------
        # Troca completa (swap) com diário
        # ------------------------------------------------------------------

        # before_load_only: só produtos cujo carregador ainda não rodou nesta sessão (abertura).
        def apply_staged(before_load_only:)
          return if other_sessions_alive?

          registered = env.extensions
          products_with_staged.each do |slug|
            pstate = product_state(slug)
            staged = pstate['staged']
            next unless staged && File.directory?(staged['dir'].to_s)

            if owned_paths(slug).empty?
              # O usuário desinstalou o plugin: não reinstala por conta própria.
              cancel_staged(slug, 'plugin não está mais instalado')
              next
            end
            if before_load_only
              next if extension_for(slug, registered)
              next unless (staged['tops'] - owned_paths(slug)).empty? # nomes novos: SketchUp só enxerga na próxima abertura
            end
            current = extension_for(slug, registered)
            if current && !newer?(staged['version'], current[:version])
              cancel_staged(slug, 'versão instalada já é igual ou mais nova')
              next
            end
            swap(slug)
          end
        end

        def swap(slug)
          lock = try_lock('update')
          return log("troca de #{slug} adiada: outra operação em andamento") unless lock

          pstate = product_state(slug)
          staged = pstate['staged']
          plugins = env.plugins_dir
          owned = owned_paths(slug)
          from_version = extension_for(slug, env.extensions)&.dig(:version) || pstate['installed_version']
          backup = File.join(work_root, 'backup', "#{slug}-#{Time.now.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}")
          moves = owned.map { |name| [File.join(plugins, name), File.join(backup, name)] } +
                  staged['tops'].map { |name| [File.join(staged['dir'], name), File.join(plugins, name)] }
          journal = {
            'op' => 'swap', 'slug' => slug, 'version' => staged['version'], 'from_version' => from_version,
            'backup' => backup, 'staging' => staged['dir'], 'moves' => moves, 'done' => 0, 'started_at' => now
          }
          write_journal(journal)
          log("trocando #{slug} #{from_version} -> #{staged['version']}")
          moves.each_with_index do |(from, to), index|
            move_path(from, to)
            journal['done'] = index + 1
            write_journal(journal)
          end

          update_product(slug) do |p|
            p['installed_version'] = staged['version']
            p['files'] = staged['tops']
            p['swapped'] = { 'version' => staged['version'], 'from_version' => from_version, 'backup' => backup, 'at' => now, 'tops' => staged['tops'], 'old_tops' => owned }
            p['staged'] = nil
            p['last_result'] = result_entry('applied', staged['version'], nil)
          end
          clear_journal
          FileUtils.rm_rf(staged['dir']) rescue nil
          log("#{slug} #{staged['version']} aplicado")
          true
        rescue StandardError, ScriptError => error
          log("troca de #{slug} falhou: #{error.class}: #{error.message}")
          rollback_journal
          update_product(slug) do |p|
            next unless p['staged']

            p['staged']['attempts'] = p['staged']['attempts'].to_i + 1
            if p['staged']['attempts'] >= MAX_SWAP_ATTEMPTS
              version = p['staged']['version']
              (p['failed'] ||= {})[version] = "troca falhou #{MAX_SWAP_ATTEMPTS}x: #{error.class}"
              FileUtils.rm_rf(p['staged']['dir']) rescue nil
              p['staged'] = nil
              p['last_result'] = result_entry('needs_restart', version,
                                              'Não foi possível concluir a atualização. Feche todas as janelas do SketchUp e abra de novo.')
            end
          end
          false
        ensure
          release_lock(lock) if lock
        end

        # Desfaz uma troca interrompida: percorre os movimentos ao contrário. Idempotente.
        def rollback_journal
          journal = read_json(journal_path)
          return if journal.empty?

          Array(journal['moves']).reverse_each do |from, to|
            next unless File.exist?(to) && !File.exist?(from)

            move_path(to, from)
          end
          clear_journal
          FileUtils.rm_rf(journal['trash']) if journal['trash'] && File.directory?(journal['trash'])
          log("operação #{journal['op']} de #{journal['slug']} desfeita")
        rescue StandardError, ScriptError => error
          log("NÃO foi possível desfazer a operação interrompida: #{error.class}: #{error.message}")
        end

        def recover_journal
          return unless File.file?(journal_path)

          log('operação interrompida encontrada; desfazendo')
          rollback_journal
        end

        # ------------------------------------------------------------------
        # Confirmação, reversão e limpeza
        # ------------------------------------------------------------------

        def confirm_swaps
          registered = env.extensions
          all_products.each do |slug, pstate|
            swapped = pstate['swapped']
            next unless swapped

            ext = extension_for(slug, registered)
            if ext && versions_equal?(ext[:version], swapped['version'])
              FileUtils.rm_rf(swapped['backup']) rescue nil
              update_product(slug) do |p|
                p['swapped'] = nil
                p['last_result'] = result_entry('updated', swapped['version'], nil)
              end
              log("#{slug} #{swapped['version']} confirmado; backup removido")
            elsif ext.nil? && !Array(swapped['tops']).any? { |name| File.exist?(File.join(env.plugins_dir, name)) }
              # O usuário desinstalou o plugin: não há o que reverter.
              FileUtils.rm_rf(swapped['backup']) rescue nil
              update_product(slug) { |p| p['swapped'] = nil }
            else
              update_product(slug) do |p|
                p['revert_pending'] = true
                (p['failed'] ||= {})[swapped['version']] = 'a nova versão não carregou no SketchUp'
                p['last_result'] = result_entry('reverting', swapped['version'], nil)
              end
              log("#{slug} #{swapped['version']} não carregou; volta para #{swapped['from_version']} ao fechar o SketchUp")
              apply_reverts if ext.nil?
            end
          end
        rescue StandardError, ScriptError => error
          log("confirmação falhou: #{error.class}: #{error.message}")
        end

        def apply_reverts
          return if other_sessions_alive?

          all_products.each do |slug, pstate|
            next unless pstate['revert_pending'] && pstate['swapped']

            revert(slug, pstate['swapped'])
          end
        end

        def revert(slug, swapped)
          lock = try_lock('update')
          return unless lock

          plugins = env.plugins_dir
          backup = swapped['backup']
          unless File.directory?(backup.to_s)
            update_product(slug) { |p| p['revert_pending'] = false }
            return
          end
          trash = File.join(work_root, 'trash', "#{slug}-#{SecureRandom.hex(4)}")
          moves = Array(swapped['tops']).select { |n| File.exist?(File.join(plugins, n)) }.map { |n| [File.join(plugins, n), File.join(trash, n)] } +
                  Dir.children(backup).map { |n| [File.join(backup, n), File.join(plugins, n)] }
          journal = { 'op' => 'revert', 'slug' => slug, 'moves' => moves, 'done' => 0, 'trash' => trash }
          write_journal(journal)
          moves.each_with_index do |(from, to), index|
            move_path(from, to)
            journal['done'] = index + 1
            write_journal(journal)
          end
          clear_journal
          FileUtils.rm_rf(trash) rescue nil
          FileUtils.rm_rf(backup) rescue nil
          update_product(slug) do |p|
            p['installed_version'] = swapped['from_version']
            p['files'] = swapped['old_tops']
            p['swapped'] = nil
            p['revert_pending'] = false
            p['last_result'] = result_entry('reverted', swapped['version'], nil)
          end
          log("#{slug} voltou para #{swapped['from_version']}")
        rescue StandardError, ScriptError => error
          log("reversão de #{slug} falhou: #{error.class}: #{error.message}")
          rollback_journal
        ensure
          release_lock(lock) if lock
        end

        # Backups sem confirmação há mais de 14 dias, staging órfão e lixo de reversões.
        def cleanup_expired
          all_products.each do |slug, pstate|
            swapped = pstate['swapped']
            next unless swapped && now - swapped['at'].to_i > BACKUP_RETENTION

            FileUtils.rm_rf(swapped['backup']) rescue nil
            update_product(slug) { |p| p['swapped'] = nil }
            log("backup de #{slug} removido após 14 dias sem confirmação")
          end
          known = all_products.values.map { |p| p.dig('staged', 'dir') }.compact
          Dir.glob(File.join(work_root, 'staging', '*')).each { |dir| FileUtils.rm_rf(dir) unless known.include?(dir) }
          FileUtils.rm_rf(File.join(work_root, 'trash'))
          Dir.glob(File.join(work_root, 'downloads', '*')).each { |file| File.delete(file) rescue nil }
        rescue StandardError, ScriptError => error
          log("limpeza falhou: #{error.class}: #{error.message}")
        end

        def cancel_staged(slug, reason)
          pstate = product_state(slug)
          return unless pstate['staged']

          FileUtils.rm_rf(pstate.dig('staged', 'dir').to_s) rescue nil
          update_product(slug) do |p|
            p['staged'] = nil
            p['last_result'] = result_entry('cancelled', nil, nil)
          end
          log("preparação de #{slug} cancelada: #{reason}")
        end

        def cancel_all_staged(reason)
          products_with_staged.each { |slug| cancel_staged(slug, reason) }
        end

        # ------------------------------------------------------------------
        # Produtos instalados e seus arquivos
        # ------------------------------------------------------------------

        # slug => { 'version', 'path' } dos plugins comprados instalados neste SketchUp.
        def installed_products
          registered = env.extensions
          known_slugs.each_with_object({}) do |slug, memo|
            ext = extension_for(slug, registered)
            memo[slug] = { 'version' => ext[:version].to_s, 'path' => ext[:path].to_s } if ext
          end
        end

        def extension_for(slug, registered)
          names = product_names(slug)
          return nil if names.empty?

          registered.find { |ext| names.include?(ext[:name]) }
        end

        # Nomes de extensão de cada produto, guardados localmente: na abertura do SketchUp a Central
        # ainda não consultou o servidor, mas precisa reconhecer os plugins instalados.
        def remember_names(items)
          st = state
          names = st['names'] ||= {}
          items.each do |item|
            list = Array(item['extension_names']).map(&:to_s).reject(&:empty?)
            names[item['slug'].to_s] = list unless list.empty?
          end
          save_state(st)
        end

        def product_names(slug)
          (Array(state.dig('names', slug)) + Array(env.extension_names(slug))).map(&:to_s).reject(&:empty?).uniq
        end

        def known_slugs
          (Array(state['names']&.keys) + Array(env.product_slugs)).map(&:to_s).uniq
        end

        # Nomes exatos (raiz da pasta Plugins) que pertencem ao produto: lista cadastrada no servidor,
        # registro local e o caminho real do plugin carregado. Só entra o que existe de fato.
        def owned_paths(slug)
          pstate = product_state(slug)
          names = Array(pstate['install_paths']) + Array(pstate['files']) + Array(pstate.dig('staged', 'install_paths'))
          names += names_from_extension_path(slug)
          plugins = env.plugins_dir
          names.map(&:to_s).uniq.select do |name|
            TOP_NAME_RE.match?(name) && !protected_name?(name) && File.exist?(File.join(plugins, name))
          end.sort
        end

        def names_from_extension_path(slug)
          ext = extension_for(slug, env.extensions)
          return [] unless ext && !ext[:path].to_s.empty?

          plugins = File.expand_path(env.plugins_dir)
          full = File.expand_path(ext[:path].to_s)
          prefix = "#{plugins}/"
          return [] unless full.downcase.start_with?(prefix.downcase)

          top = full[prefix.length..].split('/').first.to_s
          base = top.sub(/\.rb\z/i, '')
          [top.end_with?('.rb') ? top : "#{base}.rb", base]
        rescue StandardError
          []
        end

        def protected_name?(name)
          name.downcase.start_with?('central_k') || %w[. .. plugins].include?(name.downcase)
        end

        # Registro dos arquivos de um produto instalado pela Central (instalação nova).
        def record_install(slug, archive_path, version)
          bytes = File.binread(archive_path)
          tops = ZipReader.entries(bytes).map { |entry| entry[:name].split('/').first }.uniq.sort
          update_product(slug) do |p|
            p['files'] = tops
            p['installed_version'] = version
          end
        rescue StandardError, ScriptError => error
          log("registro de #{slug} falhou: #{error.class}")
        end

        # ------------------------------------------------------------------
        # Estado para a janela da Central
        # ------------------------------------------------------------------

        def status_payload
          st = state
          registered = env.extensions
          products = all_products.each_with_object({}) do |(slug, p), memo|
            ext = extension_for(slug, registered)
            memo[slug] = {
              'installed_version' => ext ? ext[:version].to_s : p['installed_version'],
              'staged_version' => p.dig('staged', 'version'),
              'last_result' => p['last_result']
            }
          end
          { 'last_check_at' => st['last_check_at'], 'last_check_result' => st['last_check_result'], 'products' => products }
        rescue StandardError
          {}
        end

        # ------------------------------------------------------------------
        # Sessões e travas
        # ------------------------------------------------------------------

        def hold_session_lock
          dir = File.join(meta_root, 'locks')
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "session-#{Process.pid}-#{SecureRandom.hex(3)}.lock")
          file = File.open(path, File::RDWR | File::CREAT, 0o644)
          if file.flock(File::LOCK_EX | File::LOCK_NB)
            @session_file = file
            @session_path = path
          else
            file.close
          end
        rescue StandardError, ScriptError => error
          log("trava de sessão indisponível: #{error.class}")
        end

        def release_session_lock
          return unless @session_file

          @session_file.flock(File::LOCK_UN) rescue nil
          @session_file.close rescue nil
          File.delete(@session_path) rescue nil
          @session_file = nil
        end

        # Outra janela do SketchUp aberta neste computador (com a Central)? Arquivos de sessões que
        # terminaram de forma inesperada ficam destravados e são apagados aqui.
        def other_sessions_alive?
          Dir.glob(File.join(meta_root, 'locks', 'session-*.lock')).any? do |path|
            next false if path == @session_path

            file = File.open(path, File::RDWR)
            if file.flock(File::LOCK_EX | File::LOCK_NB)
              file.flock(File::LOCK_UN)
              file.close
              File.delete(path) rescue nil
              false
            else
              file.close
              true
            end
          rescue Errno::ENOENT
            false
          rescue StandardError
            true
          end
        end

        def try_lock(name)
          dir = File.join(meta_root, 'locks')
          FileUtils.mkdir_p(dir)
          file = File.open(File.join(dir, "#{name}.lock"), File::RDWR | File::CREAT, 0o644)
          return file if file.flock(File::LOCK_EX | File::LOCK_NB)

          file.close
          nil
        rescue StandardError
          nil
        end

        def release_lock(file)
          return unless file

          file.flock(File::LOCK_UN) rescue nil
          file.close rescue nil
        end

        # ------------------------------------------------------------------
        # Arquivos de estado, diário e registro (log)
        # ------------------------------------------------------------------

        def meta_root
          File.join(env.data_dir, 'updates')
        end

        # Pasta de trabalho ao lado de Plugins (mesmo disco: as trocas são renomeações rápidas).
        def work_root
          File.join(File.dirname(File.expand_path(env.plugins_dir)), 'CentralK_updates')
        end

        def state_path
          File.join(meta_root, 'state.json')
        end

        def journal_path
          File.join(meta_root, 'journal.json')
        end

        def log_path
          File.join(meta_root, 'updater.log')
        end

        def state
          data = read_json(state_path)
          data['products'] ||= {}
          data
        end

        def save_state(data)
          write_json(state_path, data)
        end

        def all_products
          state['products']
        end

        def product_state(slug)
          state['products'][slug] || {}
        end

        def products_with_staged
          all_products.select { |_slug, p| p['staged'] }.keys
        end

        def update_product(slug)
          st = state
          pstate = st['products'][slug] ||= {}
          yield pstate
          save_state(st)
        end

        def mark_failed(slug, version, reason)
          update_product(slug) do |p|
            (p['failed'] ||= {})[version] = reason.to_s[0, 200]
            p['last_result'] = result_entry('rejected', version, nil)
          end
        end

        def set_last_result(slug, status, version, message)
          update_product(slug) { |p| p['last_result'] = result_entry(status, version, message) }
        end

        def result_entry(status, version, message)
          { 'status' => status, 'version' => version, 'message' => message, 'at' => now }
        end

        def write_journal(journal)
          write_json(journal_path, journal)
        end

        def clear_journal
          File.delete(journal_path) if File.exist?(journal_path)
        end

        def read_json(path)
          return {} unless File.file?(path)

          data = JSON.parse(File.read(path, encoding: 'UTF-8'))
          data.is_a?(Hash) ? data : {}
        rescue StandardError
          {}
        end

        def write_json(path, data)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.#{SecureRandom.hex(3)}.tmp"
          File.open(tmp, 'wb') do |file|
            file.write(JSON.generate(data))
            file.flush
            file.fsync rescue nil
          end
          File.rename(tmp, path)
        ensure
          File.delete(tmp) if tmp && File.exist?(tmp)
        end

        def move_path(from, to)
          FileUtils.mkdir_p(File.dirname(to))
          File.rename(from, to)
        rescue Errno::EXDEV
          FileUtils.mv(from, to)
        end

        # Registro pequeno, com rotação e sem dados pessoais (e-mails e pasta do usuário trocados).
        def log(message)
          FileUtils.mkdir_p(meta_root)
          if File.file?(log_path) && File.size(log_path) > LOG_MAX_BYTES
            File.rename(log_path, "#{log_path}.1") rescue nil
          end
          home = File.expand_path('~')
          text = message.to_s.gsub(home, '~').gsub(/[^\s@]+@[^\s@]+\.[^\s@]+/, '<email>')
          File.open(log_path, 'a') { |file| file.puts("#{Time.at(now).utc.strftime('%Y-%m-%d %H:%M:%S')}Z #{text}") }
        rescue StandardError
          nil
        end

        # ------------------------------------------------------------------
        # Versões
        # ------------------------------------------------------------------

        def version_parts(value)
          value.to_s.scan(/\d+/).map(&:to_i)
        end

        def compare(a, b)
          x = version_parts(a)
          y = version_parts(b)
          len = [x.length, y.length, 1].max
          (x + [0] * (len - x.length)) <=> (y + [0] * (len - y.length))
        end

        def newer?(candidate, current)
          compare(candidate, current).positive?
        end

        def versions_equal?(a, b)
          compare(a, b).zero?
        end

        def now
          env.now
        end
      end

      # --------------------------------------------------------------------
      # Leitura de .rbz (zip) sem bibliotecas externas: diretório central, inflate e CRC.
      # --------------------------------------------------------------------
      module ZipReader
        module_function

        def entries(bytes)
          eocd = bytes.rindex("PK\x05\x06".b, -22)
          raise Updater::Abort, 'arquivo zip inválido' unless eocd

          count = bytes.byteslice(eocd + 10, 2).unpack1('v')
          offset = bytes.byteslice(eocd + 16, 4).unpack1('V')
          raise Updater::Abort, 'zip64 não suportado' if count == 0xFFFF || offset == 0xFFFFFFFF

          list = []
          count.times do
            raise Updater::Abort, 'diretório do zip corrompido' unless bytes.byteslice(offset, 4) == "PK\x01\x02".b

            flags, method = bytes.byteslice(offset + 8, 4).unpack('vv')
            crc, csize, usize = bytes.byteslice(offset + 16, 12).unpack('VVV')
            name_len, extra_len, comment_len = bytes.byteslice(offset + 28, 6).unpack('vvv')
            local = bytes.byteslice(offset + 42, 4).unpack1('V')
            name = bytes.byteslice(offset + 46, name_len).to_s.dup.force_encoding('UTF-8')
            raise Updater::Abort, 'arquivo criptografado no zip' if flags & 1 == 1
            raise Updater::Abort, "compressão não suportada (#{method})" unless [0, 8].include?(method)
            raise Updater::Abort, 'nome de arquivo inválido no zip' unless name.valid_encoding?

            list << { name: name, method: method, crc: crc, csize: csize, size: usize, local: local } unless name.end_with?('/')
            offset += 46 + name_len + extra_len + comment_len
          end
          list
        end

        def read(bytes, entry)
          header = entry[:local]
          raise Updater::Abort, 'cabeçalho local corrompido' unless bytes.byteslice(header, 4) == "PK\x03\x04".b

          name_len, extra_len = bytes.byteslice(header + 26, 4).unpack('vv')
          start = header + 30 + name_len + extra_len
          raw = bytes.byteslice(start, entry[:csize])
          raise Updater::Abort, "arquivo incompleto: #{entry[:name]}" unless raw && raw.bytesize == entry[:csize]

          data = entry[:method] == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw) : raw
          raise Updater::Abort, "tamanho não confere: #{entry[:name]}" unless data.bytesize == entry[:size]
          raise Updater::Abort, "arquivo corrompido (CRC): #{entry[:name]}" unless Zlib.crc32(data) == entry[:crc]

          data
        rescue Zlib::Error
          raise Updater::Abort, "arquivo corrompido: #{entry[:name]}"
        end

        def extract(bytes, entries, dest)
          root = File.expand_path(dest)
          entries.each do |entry|
            target = File.expand_path(File.join(root, entry[:name]))
            raise Updater::Abort, "caminho fora da pasta: #{entry[:name]}" unless target.start_with?("#{root}/")

            data = read(bytes, entry)
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, data)
          end
        end
      end

      # --------------------------------------------------------------------
      # Ligação com o SketchUp (substituída nos testes).
      # --------------------------------------------------------------------
      class SketchupEnv
        def plugins_dir
          Sketchup.find_support_file('Plugins').to_s.tr('\\', '/')
        end

        def data_dir
          CentralKPilot.data_dir
        end

        def now
          Time.now.to_i
        end

        def sketchup_version
          Sketchup.version.to_s
        end

        def sketchup_major
          Sketchup.version.to_i
        end

        def platform
          Sketchup.platform.to_s == 'platform_win' ? 'win' : 'mac'
        end

        def extensions
          Sketchup.extensions.map do |ext|
            path = ext.respond_to?(:extension_path) ? ext.extension_path.to_s.tr('\\', '/') : ''
            { name: ext.name.to_s, version: ext.version.to_s, path: path }
          end
        rescue StandardError
          []
        end

        def product_slugs
          CentralKPilot.known_slugs
        rescue StandardError
          []
        end

        def logged_in?
          !CentralKPilot.saved_email.to_s.empty?
        end

        def extension_names(slug)
          CentralKPilot.extension_names_for(slug)
        rescue StandardError
          []
        end

        def timer(seconds, &block)
          UI.start_timer(seconds, false) do
            begin
              block.call
            rescue StandardError, ScriptError => error
              Updater.log("tarefa agendada falhou: #{error.class}: #{error.message}")
            end
          end
        end

        def on_quit(&block)
          @quit_observer = QuitObserver.new(block)
          Sketchup.add_observer(@quit_observer)
        end

        def api_post(action, payload, timeout, &complete)
          CentralKPilot.updater_api_post(action, payload, timeout, &complete)
        end

        def http_get(url, timeout, &complete)
          CentralKPilot.updater_http_get(url, timeout, &complete)
        end
      end

      class QuitObserver < Sketchup::AppObserver
        def initialize(block)
          super()
          @block = block
        end

        def onQuit
          @block.call
        end
      end
    end
  end
end
