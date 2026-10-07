# frozen_string_literal: true
require 'sketchup'
require 'json'
require 'digest'
require 'fileutils'
require 'socket'
require 'time'
require 'set'
require 'openssl'
require 'base64'

module KahDetalha
  module CentralKPilot
    API_URL = 'https://flibbkyxitkvsdnmgrcl.supabase.co'.freeze
    PUBLISHABLE_KEY = 'sb_publishable__yTAPKcnYXFCKDV2vPv1rg_SUGyWvYv'.freeze
    FUNCTION_URL = "#{API_URL}/functions/v1/central-k-api".freeze
    DEVICE_LIMIT = 2
    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/.freeze

    CENTRAL_K_VERSION = '1.0.3'.freeze
    # Pasta dos arquivos da Central (vitrine, ícones, instaladores embutidos). Vem do arquivo de
    # registro (central_k_pilot.rb), que a Trimble não criptografa: __dir__/__FILE__ não são
    # confiáveis dentro dos .rbe criptografados.
    ASSET_DIR = File.join(PLUGIN_ROOT, 'central_k_pilot').freeze
    # Versão da vitrine (ui.html + media/) que vem dentro deste pacote. Vitrines publicadas
    # depois são baixadas pela própria Central e usadas no lugar desta.
    UI_BUNDLED_VERSION = '1.0.3'.freeze
    UI_SAFE_PATH = %r{\A(?!.*\.\.)[A-Za-z0-9_\-][A-Za-z0-9_\-./ ]{0,180}\z}.freeze
    MAX_UI_FILES = 300
    MAX_UI_FILE_BYTES = 40 * 1024 * 1024
    # Renovação das autorizações: só consulta o servidor quando alguma vence em até 2 dias.
    RENEW_BEFORE_SECONDS = 2 * 24 * 60 * 60

    BUNDLED_PRODUCTS = {
      'kcenas' => {
        name: 'K.Cenas', extension_names: ['K.Cenas', 'K.Cenas Pilot'].freeze,
        version: '1.0.1', archive: 'K.CENAS V 1.0.1.rbz',
        sha256: 'B514B95C1B0603DB2FBDFEFC0A0FDC43E8EBB0799F62DB95634645FA13F004EF'
      },
      'klight' => {
        name: 'K.Light', version: '1.0.5', archive: 'K.LIGHT V 1.0.5.rbz',
        sha256: '92885843A1CBA1E4AC7FF1BD48E21A8E9C17AF9888755F1E9F9845D4397276BF'
      }
    }.freeze

    # Escala de retentativa "rápida" e visível (item 1/2 do plano): 2s, 5s,
    # 15s. Depois disso, se já havia sessão autenticada, continua tentando
    # em silêncio nesse intervalo mais espaçado, sem popup nenhum.
    # A API nativa do SketchUp evita os problemas da biblioteca HTTP antiga no
    # Ruby embarcado. Três tentativas no total (inicial + 2 retentativas), sem
    # mostrar erro ao comprador enquanto a recuperação automática está ativa.
    RETRY_DELAYS = [1, 3].freeze
    API_ATTEMPT_TIMEOUT = 8
    DOWNLOAD_ATTEMPT_TIMEOUT = 45
    MAX_PACKAGE_BYTES = 100 * 1024 * 1024
    SLOW_RETRY_SECONDS = 20 * 60
    RENEW_CHECK_SECONDS = 30 * 60
    # Ao abrir o SketchUp: espera o programa terminar de carregar e consulta o servidor no máximo
    # 1 vez por hora (atualização automática dos plugins comprados, sem abrir janela).
    STARTUP_CHECK_DELAY = 25
    STARTUP_CHECK_INTERVAL = 60 * 60

    RETRYABLE_KINDS = %i[timeout offline server_down unknown].freeze

    # Valores que dependem da API do SketchUp (Sketchup.platform/version),
    # capturados uma única vez aqui — a própria carga do .rb já roda na
    # thread principal — e nunca mais lidos de dentro de uma thread de
    # fundo (regra de threading do plano).
    PLATFORM_STR = Sketchup.platform.to_s.freeze
    SKETCHUP_VERSION_STR = Sketchup.version.to_s.freeze

    # ---------------------------------------------------------------
    # Verificação do token assinado (JWT/JWS RS256). A chave privada só
    # existe como secret da Edge Function; aqui só a pública, que é
    # informação pública mesmo. Mapa por "kid" pensando em rotação futura.
    # ---------------------------------------------------------------
    module TokenVerify
      MAX_TOKEN_BYTES = 8 * 1024

      PUBLIC_KEYS = {
        'ck-2026-08' => <<~PEM
          -----BEGIN PUBLIC KEY-----
          MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmyJQvlxgSHFwmCpWC4FY
          FMFuzaOXvJGwicgEz7s0b1YbYYGB7j5nYs0hC+3xyXj7omVn3kACr+EMU8/LxOhW
          DFu7PPUMMF8E/DulA9NVYnrSZVERS2KA9B/ouGnbskPRmouTXNLpmXiFuoGsinvC
          +S0sqXu22Me1tLi6QCaFW8QNChXSu+p4LoQW+qxWyUnycy7zOvvCqBrcR31fhUZi
          naeMdGZ2BsKpwfcF6HofMznl/4NSp5zj2143PTQJI2IHiy8X9cDTmGuJTR00WuF4
          7YjrwEo1fyat4zcPGfPrFRk4FU+kOrOTawOhTNCg70WFWKESYxf5/OFHjPyuRLDB
          9wIDAQAB
          -----END PUBLIC KEY-----
        PEM
      }.freeze

      def self.b64url_decode(str)
        str = str.to_s.tr('-_', '+/')
        str += '=' * ((4 - (str.length % 4)) % 4)
        Base64.decode64(str)
      end

      # Verifica assinatura, estrutura e campos do token pra um slug e
      # device_hash esperados. Qualquer coisa fora do esperado -> nil,
      # sem tentar "aproveitar" o que der (ponto 8 do plano).
      def self.verify(token, expected_slug, expected_device_hash)
        return nil if token.to_s.empty? || token.to_s.bytesize > MAX_TOKEN_BYTES

        parts = token.to_s.split('.')
        return nil unless parts.length == 3
        header_b64, payload_b64, sig_b64 = parts

        header = JSON.parse(b64url_decode(header_b64)) rescue nil
        return nil unless header.is_a?(Hash)
        return nil unless header['alg'] == 'RS256' && header['typ'] == 'JWT'

        pubkey_pem = PUBLIC_KEYS[header['kid']]
        return nil unless pubkey_pem

        signing_input = "#{header_b64}.#{payload_b64}"
        signature = b64url_decode(sig_b64)
        pkey = OpenSSL::PKey::RSA.new(pubkey_pem)
        return nil unless pkey.verify(OpenSSL::Digest::SHA256.new, signature, signing_input)

        payload = JSON.parse(b64url_decode(payload_b64)) rescue nil
        return nil unless payload.is_a?(Hash)
        return nil unless payload['version'] == 1
        return nil unless payload['exp'].is_a?(Integer) && payload['iat'].is_a?(Integer)
        return nil unless payload['user_id'].is_a?(String) && !payload['user_id'].empty?
        return nil unless payload['product_slug'].is_a?(String) && payload['device_hash'].is_a?(String)
        return nil unless payload['product_slug'] == expected_slug
        return nil unless payload['device_hash'] == expected_device_hash
        return nil unless payload['exp'] > Time.now.to_i

        payload
      rescue StandardError
        nil
      end

      # exp de um token, sem validar assinatura (só pra decidir "está perto
      # de vencer, vale a pena tentar renovar" — decisão de UI, não de
      # segurança; a segurança é sempre re-verificada no `verify` acima).
      def self.peek_exp(token)
        parts = token.to_s.split('.')
        return nil unless parts.length == 3
        payload = JSON.parse(b64url_decode(parts[1])) rescue nil
        payload.is_a?(Hash) ? payload['exp'] : nil
      rescue StandardError
        nil
      end
    end

    class << self
      # ---------------------------------------------------------------
      # Local storage
      # ---------------------------------------------------------------

      def data_dir
        base = ENV['LOCALAPPDATA'].to_s
        base = ENV['APPDATA'].to_s if base.empty?
        base = File.expand_path('~') if base.empty?
        File.join(base, 'KahDetalha', 'CentralKPilot')
      end

      def session_path
        File.join(data_dir, 'session.json')
      end

      def license_path(slug)
        raise ArgumentError, 'slug inválido' unless slug.to_s.match?(/\A[a-z0-9_]+\z/)

        File.join(data_dir, 'licenses', "#{slug}.json")
      end

      def read_json(path)
        return {} unless File.file?(path)
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue StandardError
        {}
      end

      def write_json(path, value)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.open(tmp, 'wb') { |file| file.write(JSON.pretty_generate(value)) }
        File.rename(tmp, path)
      end

      def saved_email
        session['email'].to_s
      end

      def session
        read_json(session_path)
      end

      def save_email(email)
        write_json(session_path, { 'email' => email })
      end

      def clear_session
        cancel_account_network if respond_to?(:cancel_account_network)
        @account_generation = (@account_generation || 0) + 1
        File.delete(session_path) if File.file?(session_path)
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------
      # Device fingerprint — só leitura de registro/Ruby puro, nenhuma
      # API do SketchUp aqui dentro (usa PLATFORM_STR já capturado), por
      # isso pode rodar tanto na thread principal quanto na de fundo.
      # ---------------------------------------------------------------

      def machine_source
        if PLATFORM_STR == 'platform_win'
          require 'win32/registry'
          Win32::Registry::HKEY_LOCAL_MACHINE.open('SOFTWARE\\Microsoft\\Cryptography') do |reg|
            reg['MachineGuid'].to_s.strip
          end
        else
          raw = `ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null`.to_s
          raw[/"IOPlatformUUID"\s*=\s*"([^"]+)"/, 1].to_s.strip
        end
      rescue StandardError
        ''
      end

      def device_hash
        @device_hash ||= begin
          source = machine_source
          source = "#{Socket.gethostname}|#{ENV['USERNAME']}|#{ENV['USER']}" if source.to_s.empty?
          Digest::SHA256.hexdigest("central-k-pilot-v1|#{source}")
        end
      end

      def device_name
        @device_name ||= begin
          host = Socket.gethostname.to_s.strip
          host.empty? ? 'Meu computador' : host
        end
      rescue StandardError
        'Meu computador'
      end

      # ---------------------------------------------------------------
      # Runner assíncrono: `work` roda numa thread secundária e só pode
      # fazer rede/hash/arquivo/JWT — nada de Sketchup.*/UI.*. `complete`
      # roda de volta na thread principal (via UI.start_timer fazendo o
      # polling) e é o único lugar autorizado a chamar API do SketchUp.
      # ---------------------------------------------------------------

      def inflight
        @inflight ||= Set.new
      end

      # @last_state nunca é lido cru — antes da primeira resposta bem
      # sucedida ele não existe, e ler direto (@last_state['x']) em nil
      # derruba o callback com NoMethodError sem avisar nada na tela
      # (parece "carregando pra sempre"). Esse getter garante um Hash
      # sempre, mesmo antes do primeiro bootstrap.
      def last_state
        @last_state ||= {}
      end

      # ---------------------------------------------------------------
      # Classificação de erro das chamadas HTTP nativas do SketchUp
      # ---------------------------------------------------------------

      DECLINED_ERRORS = %w[no_purchases device_blocked not_entitled device_limit_reached invalid_email
                           invalid_device product_not_found invalid_token].freeze

      def classify(code, body)
        return :timeout if code == -1
        return :offline if code == -2
        return :ok if code.between?(200, 299)
        return :declined if body.is_a?(Hash) && DECLINED_ERRORS.include?(body['error'])
        return :server_down if code >= 500 || code == 429 || code <= 0
        :unknown
      end

      # HTTP nativo do SketchUp para conta/licença. Mantemos uma referência
      # forte ao Request porque a API pode cancelar silenciosamente a operação
      # se o objeto for coletado antes do callback.
      def cancel_account_network
        if @account_retry_timer
          UI.stop_timer(@account_retry_timer) rescue nil
          @account_retry_timer = nil
        end
        if @account_timeout_timer
          UI.stop_timer(@account_timeout_timer) rescue nil
          @account_timeout_timer = nil
        end
        if @account_http_request
          @account_http_request.cancel rescue nil
          @account_http_request = nil
        end
      end

      # A instalação usa uma requisição nativa própria. Ela não compartilha
      # estado com o bootstrap, portanto um refresh do catálogo não cancela
      # silenciosamente a autorização que o comprador acabou de iniciar.
      def cancel_install_network
        if @install_retry_timer
          UI.stop_timer(@install_retry_timer) rescue nil
          @install_retry_timer = nil
        end
        if @install_timeout_timer
          UI.stop_timer(@install_timeout_timer) rescue nil
          @install_timeout_timer = nil
        end
        if @install_http_request
          @install_http_request.cancel rescue nil
          @install_http_request = nil
        end
        @install_busy = false
        @install_queue = []
        @install_messages = []
        @install_success_count = 0
      end

      def native_install_api_post(slug, generation, attempt = 0, &complete)
        request = Sketchup::Http::Request.new(FUNCTION_URL, Sketchup::Http::POST)
        request.headers = {
          'Content-Type' => 'application/json; charset=utf-8',
          'Accept' => 'application/json',
          'apikey' => PUBLISHABLE_KEY
        }
        request.body = JSON.generate(
          action: 'activate', email: saved_email, product_slug: slug,
          device_hash: device_hash, friendly_name: device_name,
          platform: PLATFORM_STR, sketchup_version: SKETCHUP_VERSION_STR,
          client_version: CENTRAL_K_VERSION
        )
        @install_http_request = request

        @install_timeout_timer = UI.start_timer(API_ATTEMPT_TIMEOUT, false) do
          next unless generation == @install_generation && @install_http_request.equal?(request)
          @install_timeout_timer = nil
          @install_http_request = nil
          request.cancel rescue nil
          handle_install_http_result(slug, generation, attempt, -1, { 'error' => 'timeout' }, &complete)
        end

        started = request.start do |_finished_request, response|
          next unless generation == @install_generation && @install_http_request.equal?(request)
          UI.stop_timer(@install_timeout_timer) rescue nil if @install_timeout_timer
          @install_timeout_timer = nil
          @install_http_request = nil
          code = response ? response.status_code.to_i : 0
          raw = response ? response.body.to_s : ''
          body = raw.empty? ? {} : (JSON.parse(raw) rescue {})
          handle_install_http_result(slug, generation, attempt, code, body, &complete)
        end

        unless started
          UI.stop_timer(@install_timeout_timer) rescue nil if @install_timeout_timer
          @install_timeout_timer = nil
          @install_http_request = nil
          handle_install_http_result(slug, generation, attempt, 0, { 'error' => 'network_error' }, &complete)
        end
      rescue StandardError => error
        warn("[Central K] Instalação/API: #{error.class}: #{error.message}")
        handle_install_http_result(slug, generation, attempt, 0, { 'error' => 'network_error' }, &complete)
      end

      def handle_install_http_result(slug, generation, attempt, code, body, &complete)
        return unless generation == @install_generation
        kind = classify(code, body)
        if RETRYABLE_KINDS.include?(kind) && attempt < RETRY_DELAYS.length
          render_install_pending(slug, "Conexão instável; tentando novamente… (#{attempt + 2} de #{RETRY_DELAYS.length + 1})")
          @install_retry_timer = UI.start_timer(RETRY_DELAYS[attempt], false) do
            next unless generation == @install_generation
            @install_retry_timer = nil
            native_install_api_post(slug, generation, attempt + 1, &complete)
          end
          return
        end
        complete.call(kind, body)
      end

      def native_api_post(action, payload, generation, &complete)
        request = Sketchup::Http::Request.new(FUNCTION_URL, Sketchup::Http::POST)
        request.headers = {
          'Content-Type' => 'application/json; charset=utf-8',
          'Accept' => 'application/json',
          'apikey' => PUBLISHABLE_KEY
        }
        request.body = JSON.generate(payload.merge(action: action, email: saved_email, client_version: CENTRAL_K_VERSION))
        @account_http_request = request

        @account_timeout_timer = UI.start_timer(API_ATTEMPT_TIMEOUT, false) do
          next unless generation == @account_generation && @account_http_request.equal?(request)
          @account_timeout_timer = nil
          @account_http_request = nil
          request.cancel rescue nil
          warn("[Central K] API #{action}: timeout local após #{API_ATTEMPT_TIMEOUT}s")
          complete.call(-1, { 'error' => 'timeout' })
        end

        started = request.start do |_finished_request, response|
          next unless generation == @account_generation && @account_http_request.equal?(request)
          UI.stop_timer(@account_timeout_timer) rescue nil if @account_timeout_timer
          @account_timeout_timer = nil
          @account_http_request = nil

          begin
            code = response ? response.status_code.to_i : 0
            raw = response ? response.body.to_s : ''
            parsed = raw.empty? ? {} : (JSON.parse(raw) rescue {})
            warn("[Central K] API #{action}: HTTP #{code}") unless code.between?(200, 299)
          rescue StandardError => error
            warn("[Central K] API #{action} callback: #{error.class}: #{error.message}")
            code = 0
            parsed = { 'error' => 'network_error' }
          end
          complete.call(code, parsed)
        end

        unless started
          UI.stop_timer(@account_timeout_timer) rescue nil if @account_timeout_timer
          @account_timeout_timer = nil
          @account_http_request = nil
          warn("[Central K] API #{action}: Sketchup::Http recusou iniciar a requisição")
          complete.call(0, { 'error' => 'network_error' })
        end
      rescue StandardError => error
        @account_http_request = nil
        warn("[Central K] API #{action}: #{error.class}: #{error.message}")
        complete.call(0, { 'error' => 'network_error' })
      end

      # ---------------------------------------------------------------
      # Bootstrap / renovação silenciosa pela API assíncrona nativa.
      # ---------------------------------------------------------------

      def request_state(message = nil, attempt = 0, generation = nil)
        email = saved_email
        if email.empty?
          cancel_account_network
          render_state({ 'authenticated' => false })
          return
        end
        if generation.nil?
          cancel_account_network
          @account_generation = (@account_generation || 0) + 1
          generation = @account_generation
        end
        current_device_hash = device_hash
        native_api_post('bootstrap', { device_hash: current_device_hash }, generation) do |code, body|
          next unless generation == @account_generation
          kind = classify(code, body)
          outcome = { kind: kind, body: body }
          outcome = process_bootstrap_body(outcome, body, current_device_hash) if kind == :ok
          handle_bootstrap_result(:ok, outcome, email, current_device_hash, message, attempt, generation)
        end
      end

      def process_bootstrap_body(outcome, body, current_device_hash)
        current_device_id = body['current_device_id']
        begin
          outcome[:revoked_slugs] = revoke_stale_local_licenses(body, current_device_id)
        rescue StandardError => error
          warn("[Central K] Limpeza local: #{error.class}: #{error.message}")
          outcome[:local_warning] = "license_cleanup_failed: #{error.class}"
          outcome[:revoked_slugs] = []
        end

        if body['device_blocked']
          outcome[:kind] = :device_blocked
        elsif !body['has_purchases']
          outcome[:kind] = :no_purchases
        else
          begin
            outcome[:written_slugs] = write_tokens_locally(body['tokens'] || {}, current_device_hash)
          rescue StandardError => error
            warn("[Central K] Gravação de token: #{error.class}: #{error.message}")
            outcome[:local_warning] = "license_write_failed: #{error.class}"
            outcome[:written_slugs] = []
          end
        end
        outcome
      end

      def handle_bootstrap_result(status, outcome, email, current_device_hash, message, attempt, generation = @account_generation)
        outcome = { kind: :server_down } if status == :error
        kind = outcome[:kind]
        body = outcome[:body] || {}

        case kind
        when :ok
          # Sketchup.extensions só pode ser lido na thread principal —
          # é por isso que `installed_extensions` roda aqui, não no BG.
          @last_state = body.merge(
            'authenticated' => true,
            'current_device_hash' => current_device_hash,
            'device_limit' => DEVICE_LIMIT,
            'installs' => installed_extensions(body['products']),
            'central_k_update' => central_k_update_info(body['central_k'])
          )
          payload = @last_state.dup
          payload['message'] = message if message
          payload['message'] ||= restart_message if @central_installed_pending
          revoked = outcome[:revoked_slugs]
          payload['revoked_products'] = revoked if revoked && !revoked.empty?
          payload['local_warning'] = outcome[:local_warning] if outcome[:local_warning]
          render_state(payload)
          auto_update_central_k
          auto_update_plugins
          maybe_update_vitrine(body['central_k'])
        when :device_blocked
          render_state(unauthenticated_payload('device_limit', email))
        when :no_purchases
          render_state(unauthenticated_payload('no_purchases', email))
        when :declined
          render_state(unauthenticated_payload(reason_for(body), email))
        else
          handle_retryable_bootstrap(email, message, attempt, generation)
        end
      end

      def handle_retryable_bootstrap(email, message, attempt, generation)
        return unless generation == @account_generation
        was_authenticated = !!last_state['authenticated']

        if attempt < RETRY_DELAYS.length
          if was_authenticated
            render_state(current_authenticated_payload)
          else
            render_login_pending('Conexão instável; tentando novamente…')
          end
          @account_retry_timer = UI.start_timer(RETRY_DELAYS[attempt], false) do
            next unless generation == @account_generation
            @account_retry_timer = nil
            request_state(message, attempt + 1, generation)
          end
        elsif was_authenticated
          render_state(current_authenticated_payload('Não foi possível atualizar agora. Seus dados já carregados continuam disponíveis.'))
        else
          render_state(unauthenticated_payload('connection_failed', email))
        end
      end

      def render_login_pending(text)
        return unless @dialog && @dialog.visible?
        @dialog.execute_script("window.showLoginPending(#{JSON.generate(text)});")
      end

      def unauthenticated_payload(reason, email, extra = {})
        { 'authenticated' => false, 'blocked_reason' => reason, 'attempted_email' => email }.merge(extra)
      end

      def current_authenticated_payload(message = nil)
        payload = last_state.dup
        payload['message'] = message if message
        payload
      end

      # ---------------------------------------------------------------
      # Revogação local — recebe o device_id explícito da própria resposta
      # do bootstrap (nunca lê uma ivar que outra operação concorrente
      # possa ter alterado — ponto 5 do 2º round do plano).
      # ---------------------------------------------------------------

      def revoke_stale_local_licenses(body, current_device_id)
        products_by_id = (body['products'] || []).each_with_object({}) { |p, h| h[p['id']] = p }
        entitled_product_ids = (body['entitlements'] || [])
                                .select { |e| e['status'] == 'active' }
                                .map { |e| e['product_id'] }.to_set
        activated_product_ids = (body['activations'] || [])
                                 .select { |a| a['device_id'] == current_device_id && a['revoked_at'].nil? }
                                 .map { |a| a['product_id'] }.to_set

        revoked = []
        known_slugs(body['products']).each do |slug|
          path = license_path(slug)
          next unless File.file?(path)
          product = products_by_id.values.find { |p| p['slug'] == slug }
          product_id = product && product['id']
          still_valid = product_id && entitled_product_ids.include?(product_id) && activated_product_ids.include?(product_id)
          next if still_valid
          File.delete(path)
          revoked << slug
        rescue StandardError
          nil
        end
        revoked
      end

      def write_tokens_locally(tokens, current_device_hash)
        written = []
        (tokens || {}).each do |slug, token|
          next unless TokenVerify.verify(token, slug, current_device_hash)
          write_json(license_path(slug), { 'token' => token })
          written << slug
        end
        written
      end

      # ---------------------------------------------------------------
      # Instalação / ativação
      # ---------------------------------------------------------------

      # Produtos do catálogo vêm do servidor (ck_products). BUNDLED_PRODUCTS só guarda os
      # instaladores que viajam dentro deste pacote (uso offline) e nomes antigos de extensão.
      # Assim um plugin novo entra na Central só pelo Supabase, sem atualizar o código.
      def server_products(products = nil)
        list = products || last_state['products'] || []
        list.select { |p| p.is_a?(Hash) && !p['grants_all'] && p['slug'].to_s.match?(/\A[a-z0-9_]+\z/) }
      end

      def known_slugs(products = nil)
        (BUNDLED_PRODUCTS.keys + server_products(products).map { |p| p['slug'] }).uniq
      end

      def extension_names_for(slug, products = nil)
        bundled = BUNDLED_PRODUCTS[slug]
        names = bundled ? (bundled[:extension_names] || [bundled[:name]]) : []
        meta = server_products(products).find { |p| p['slug'] == slug }
        names += [meta['extension_name'].to_s] if meta && !meta['extension_name'].to_s.strip.empty?
        names.uniq
      end

      def installed_extensions(products = nil)
        found = {}
        names_by_slug = known_slugs(products).each_with_object({}) { |slug, memo| memo[slug] = extension_names_for(slug, products) }
        Sketchup.extensions.each do |extension|
          names_by_slug.each do |slug, extension_names|
            next unless extension_names.include?(extension.name.to_s)
            pending = (@plugin_installed_pending || {})[slug]
            found[slug] = {
              'installed' => true,
              # Atualizado nesta sessão (vale ao reiniciar o SketchUp): já conta como versão nova.
              'version' => pending || extension.version.to_s,
              'loaded' => (extension.respond_to?(:loaded?) ? extension.loaded? : true),
              'path' => (extension.respond_to?(:extension_path) ? extension.extension_path.to_s : '')
            }
          end
        end
        found
      rescue StandardError
        {}
      end

      def bundled_archive(slug)
        product = BUNDLED_PRODUCTS[slug]
        return nil unless product
        File.join(ASSET_DIR, 'packages', product[:archive])
      end

      def remote_product_meta(slug)
        products = last_state['products'] || []
        products.find { |p| p['slug'] == slug }
      end

      def download_cache_path(slug, sha256)
        File.join(data_dir, 'downloads', "#{slug}-#{sha256[0, 12].downcase}.rbz")
      end

      def product_display_name(slug)
        meta = remote_product_meta(slug)
        name = meta && meta['name'].to_s.strip
        return name unless name.to_s.empty?
        bundled = BUNDLED_PRODUCTS[slug]
        bundled ? bundled[:name] : slug
      end

      def valid_bundled_archive(slug, require_current: true)
        bundled = BUNDLED_PRODUCTS[slug]
        path = bundled_archive(slug)
        return nil unless bundled && path && File.file?(path)
        if require_current
          meta = remote_product_meta(slug)
          return nil unless meta && compare_versions(meta['current_version'], bundled[:version]).zero?
        end
        return nil unless Digest::SHA256.file(path).hexdigest.upcase == bundled[:sha256]
        path
      rescue StandardError
        nil
      end

      # Download binário pela API nativa do SketchUp. Os botões de instalar,
      # atualizar e atualizar tudo usam exclusivamente a API nativa.
      def native_download_archive(slug, url, expected_hash, generation, attempt = 0, &complete)
        request = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
        request.headers = { 'Accept' => 'application/octet-stream' }
        @install_http_request = request
        @install_timeout_timer = UI.start_timer(DOWNLOAD_ATTEMPT_TIMEOUT, false) do
          next unless generation == @install_generation && @install_http_request.equal?(request)
          @install_timeout_timer = nil
          @install_http_request = nil
          request.cancel rescue nil
          handle_download_result(slug, url, expected_hash, generation, attempt, 0, nil, &complete)
        end

        started = request.start do |_finished_request, response|
          next unless generation == @install_generation && @install_http_request.equal?(request)
          UI.stop_timer(@install_timeout_timer) rescue nil if @install_timeout_timer
          @install_timeout_timer = nil
          @install_http_request = nil
          code = response ? response.status_code.to_i : 0
          bytes = response ? response.body.to_s : nil
          handle_download_result(slug, url, expected_hash, generation, attempt, code, bytes, &complete)
        end
        unless started
          UI.stop_timer(@install_timeout_timer) rescue nil if @install_timeout_timer
          @install_timeout_timer = nil
          @install_http_request = nil
          handle_download_result(slug, url, expected_hash, generation, attempt, 0, nil, &complete)
        end
      rescue StandardError => error
        warn("[Central K] Download #{slug}: #{error.class}: #{error.message}")
        handle_download_result(slug, url, expected_hash, generation, attempt, 0, nil, &complete)
      end

      def handle_download_result(slug, url, expected_hash, generation, attempt, code, bytes, &complete)
        return unless generation == @install_generation
        valid_response = code.between?(200, 299) && bytes && bytes.bytesize.positive? && bytes.bytesize <= MAX_PACKAGE_BYTES
        if valid_response
          actual_hash = Digest::SHA256.hexdigest(bytes).upcase
          if actual_hash == expected_hash
            path = download_cache_path(slug, expected_hash)
            FileUtils.mkdir_p(File.dirname(path))
            tmp = "#{path}.tmp"
            File.open(tmp, 'wb') { |file| file.write(bytes) }
            File.rename(tmp, path)
            complete.call(path, nil)
            return
          end
          complete.call(nil, 'O arquivo recebido não passou na verificação de segurança.')
          return
        end

        if attempt < RETRY_DELAYS.length
          render_install_pending(slug, "Download interrompido; tentando novamente… (#{attempt + 2} de #{RETRY_DELAYS.length + 1})")
          @install_retry_timer = UI.start_timer(RETRY_DELAYS[attempt], false) do
            next unless generation == @install_generation
            @install_retry_timer = nil
            native_download_archive(slug, url, expected_hash, generation, attempt + 1, &complete)
          end
        else
          complete.call(nil, 'Não foi possível baixar o plugin. Verifique sua conexão e tente novamente.')
        end
      rescue StandardError => error
        warn("[Central K] Cache #{slug}: #{error.class}: #{error.message}")
        complete.call(nil, 'Não foi possível salvar o instalador neste computador.')
      end

      def prepare_archive_native(slug, generation, &complete)
        bundled = valid_bundled_archive(slug, require_current: true)
        if bundled
          complete.call(bundled, nil)
          return
        end

        meta = remote_product_meta(slug)
        url = meta && meta['download_url'].to_s
        expected_hash = meta && meta['download_sha256'].to_s.upcase
        unless url.to_s.start_with?('https://') && expected_hash.to_s.match?(/\A[A-F0-9]{64}\z/)
          complete.call(nil, 'O instalador deste plugin ainda não foi publicado.')
          return
        end

        cached = download_cache_path(slug, expected_hash)
        if File.file?(cached)
          if Digest::SHA256.file(cached).hexdigest.upcase == expected_hash
            complete.call(cached, nil)
            return
          end
          File.delete(cached) rescue nil
        end

        render_install_pending(slug, 'Baixando o plugin…')
        native_download_archive(slug, url, expected_hash, generation, &complete)
      end

      def entitled_slugs
        return [] unless last_state['authenticated']
        all_access = !!last_state['all_access']
        entitled_ids = (last_state['entitlements'] || []).select { |e| e['status'] == 'active' }.map { |e| e['product_id'] }.to_set
        products_by_slug = (last_state['products'] || []).each_with_object({}) { |p, h| h[p['slug']] = p }
        known_slugs.select do |slug|
          product = products_by_slug[slug]
          product && (all_access || entitled_ids.include?(product['id']))
        end
      end

      def entitled_uninstalled_slugs
        installed = installed_extensions
        entitled_slugs.reject { |slug| installed.dig(slug, 'installed') }
      end

      def entitled_installed_slugs
        installed = installed_extensions
        entitled_slugs.select { |slug| installed.dig(slug, 'installed') }
      end

      def version_parts(value)
        value.to_s.sub(/\Av\s*/i, '').scan(/\d+/).map(&:to_i)
      end

      def compare_versions(left, right)
        a = version_parts(left)
        b = version_parts(right)
        length = [a.length, b.length, 1].max
        (a + [0] * (length - a.length)) <=> (b + [0] * (length - b.length))
      end

      def newer_version?(candidate, current)
        compare_versions(candidate, current).positive?
      end

      def entitled_outdated_slugs
        installed = installed_extensions
        entitled_installed_slugs.select do |slug|
          meta = remote_product_meta(slug)
          meta && newer_version?(meta['current_version'], installed.dig(slug, 'version'))
        end
      end

      def install_product(slug)
        start_native_install_queue([slug])
      end

      # Instalação individual e atualização em lote compartilham a mesma
      # fila e a mesma trava. Assim nunca existem duas chamadas concorrentes
      # a Sketchup.install_from_archive nem mensagens disputando a interface.
      def start_native_install_queue(slugs, silent: false)
        allowed = entitled_slugs.to_set
        queue = slugs.map(&:to_s).uniq.select { |slug| allowed.include?(slug) }
        if queue.empty?
          render_state(current_authenticated_payload('Sua compra não autoriza este plugin. Atualize o catálogo e tente novamente.')) unless silent
          return
        end
        if @install_busy || @central_update_busy
          render_install_pending(queue.first, 'Uma instalação ou atualização já está em andamento…') unless silent
          return
        end

        @install_silent = silent
        @install_busy = true
        @install_generation = (@install_generation || 0) + 1
        @install_queue = queue
        @install_messages = []
        @install_success_count = 0
        install_next_native_product(@install_generation)
      end

      def install_next_native_product(generation)
        return unless generation == @install_generation
        slug = @install_queue.shift
        unless slug
          @install_busy = false
          if @install_silent
            # Atualização automática: nada de mensagens; só atualiza a janela se estiver aberta.
            @install_silent = false
            warn("[Central K] Atualização automática: #{@install_messages.join(' ')}") unless @install_messages.empty?
            render_state(current_authenticated_payload)
            return
          end
          message = @install_messages.join(' ')
          message += ' Reinicie o SketchUp para usar as alterações.' if @install_success_count.to_i.positive?
          request_state(message)
          return
        end

        current_device_hash = device_hash
        render_install_pending(slug, 'Confirmando sua licença…')

        native_install_api_post(slug, generation) do |kind, body|
          next unless generation == @install_generation
          if kind != :ok
            @install_messages << "#{product_display_name(slug)}: #{error_message(body || {})}"
            install_next_native_product(generation)
            next
          end

          token = body['token'].to_s
          unless TokenVerify.verify(token, slug, current_device_hash)
            @install_messages << "#{product_display_name(slug)}: não foi possível confirmar a autorização."
            install_next_native_product(generation)
            next
          end

          prepare_archive_native(slug, generation) do |archive, archive_error|
            next unless generation == @install_generation
            unless archive
              @install_messages << "#{product_display_name(slug)}: #{archive_error}"
              install_next_native_product(generation)
              next
            end

            name = product_display_name(slug)
            render_install_pending(slug, 'Instalando no SketchUp…')
            begin
              installed = clean_install(slug, archive)
              if installed
                write_json(license_path(slug), { 'token' => token })
                meta = remote_product_meta(slug)
                (@plugin_installed_pending ||= {})[slug] = meta['current_version'].to_s if meta && !meta['current_version'].to_s.empty?
                @install_success_count += 1
                @install_messages << "#{name} foi instalado."
              else
                @install_messages << "O SketchUp não concluiu a instalação de #{name}."
              end
              install_next_native_product(generation)
            rescue Interrupt
              finish_product_install('Instalação cancelada.', false)
            rescue Exception => error
              @install_messages << "Falha ao instalar #{name}: #{error.message}"
              install_next_native_product(generation)
            end
          end
        end
      end

      def render_install_pending(slug, text)
        return unless @dialog && @dialog.visible?
        @dialog.execute_script("window.showInstallPending(#{JSON.generate(slug)}, #{JSON.generate(text)});")
      end

      def finish_product_install(message, ok)
        cancel_install_network
        @install_generation = (@install_generation || 0) + 1
        render_state(current_authenticated_payload(message).merge('message_ok' => ok))
      end

      # ---------------------------------------------------------------
      # Atualização automática dos plugins comprados
      # ---------------------------------------------------------------

      # Depois de cada consulta ao servidor: plugin comprado, instalado e com versão nova publicada
      # -> baixa e instala em segundo plano, sem janela. Vale ao reabrir o SketchUp.
      # Uma tentativa por versão em cada sessão (se falhar, tenta de novo na próxima abertura).
      def auto_update_plugins
        return if @install_busy || @central_update_busy

        @plugin_auto_attempted ||= {}
        slugs = entitled_outdated_slugs.select do |slug|
          version = remote_product_meta(slug)&.dig('current_version').to_s
          next false if version.empty? || @plugin_auto_attempted[slug] == version

          @plugin_auto_attempted[slug] = version
          true
        end
        start_native_install_queue(slugs, silent: true) unless slugs.empty?
      rescue StandardError => error
        warn("[Central K] Atualização automática dos plugins: #{error.class}: #{error.message}")
      end

      # Consulta silenciosa ao abrir o SketchUp (no máximo 1 vez por hora).
      def startup_check
        return if saved_email.empty?
        return if @dialog && @dialog.visible?

        stamp = File.join(data_dir, 'last_startup_check.json')
        last = read_json(stamp)['at'].to_i
        return if Time.now.to_i - last < STARTUP_CHECK_INTERVAL

        write_json(stamp, { 'at' => Time.now.to_i })
        request_state
      rescue StandardError => error
        warn("[Central K] Verificação ao abrir: #{error.class}: #{error.message}")
      end

      # Instalação limpa de uma atualização: a pasta antiga do plugin sai inteira antes de instalar
      # (arquivos que não existem mais na versão nova não ficam para trás). Se algo der errado,
      # a pasta antiga volta para o lugar. Sem pasta antiga identificável, instala por cima.
      def clean_install(slug, archive)
        folder = old_plugin_folder(slug, archive)
        backup = nil
        if folder
          backup = File.join(data_dir, 'backup', "#{File.basename(folder)}-#{Time.now.to_i}")
          begin
            FileUtils.mkdir_p(File.dirname(backup))
            FileUtils.mv(folder, backup)
          rescue StandardError => error
            warn("[Central K] Limpeza da versão antiga de #{slug}: #{error.class}: #{error.message}")
            restore_plugin_folder(backup, folder) if backup && File.directory?(backup)
            backup = nil
          end
        end

        installed = false
        begin
          installed = Sketchup.install_from_archive(archive, false)
        ensure
          if backup
            if installed && File.directory?(folder)
              FileUtils.rm_rf(backup) rescue nil
            else
              restore_plugin_folder(backup, folder)
            end
          end
        end
        installed
      end

      def restore_plugin_folder(backup, folder)
        FileUtils.rm_rf(folder) if File.directory?(folder)
        FileUtils.mv(backup, folder)
      rescue StandardError => error
        warn("[Central K] Não foi possível restaurar #{folder}: #{error.class}: #{error.message}")
      end

      # Pasta do plugin instalado, só quando o pacote novo traz uma pasta com o mesmo nome
      # (assim o carregador novo sempre encontra os próprios arquivos).
      def old_plugin_folder(slug, archive)
        path = installed_extensions.dig(slug, 'path').to_s
        return nil if path.empty?

        plugins_dir = File.expand_path(Sketchup.find_support_file('Plugins').to_s)
        return nil if plugins_dir.empty?

        full = File.expand_path(path)
        prefix = plugins_dir.end_with?('/') ? plugins_dir : "#{plugins_dir}/"
        return nil unless full.downcase.start_with?(prefix.downcase)

        top = full[prefix.length..].to_s.split('/').first.to_s
        name = top.sub(/\.rb\z/i, '')
        return nil if name.empty? || name.start_with?('.') || name.include?('central_k')

        folder = File.join(plugins_dir, name)
        return nil unless File.directory?(folder)
        return nil unless archive_top_folders(archive).any? { |entry| entry.casecmp?(name) }

        folder
      rescue StandardError
        nil
      end

      # Pastas da raiz de um .rbz (zip), lidas do diretório central do arquivo.
      def archive_top_folders(archive)
        data = File.binread(archive)
        eocd = data.rindex("PK\x05\x06".b, -22)
        return [] unless eocd

        count = data[eocd + 10, 2].unpack1('v')
        offset = data[eocd + 16, 4].unpack1('V')
        names = []
        count.times do
          break unless data[offset, 4] == "PK\x01\x02".b

          name_len, extra_len, comment_len = data[offset + 28, 6].unpack('vvv')
          names << data[offset + 46, name_len].to_s.force_encoding('UTF-8').tr('\\', '/')
          offset += 46 + name_len + extra_len + comment_len
        end
        names.select { |entry| entry.include?('/') }.map { |entry| entry.split('/').first }.uniq
      rescue StandardError
        []
      end

      def update_all
        slugs = entitled_outdated_slugs
        if slugs.empty?
          render_state(current_authenticated_payload('Seus plugins já estão atualizados.'))
          return
        end
        start_native_install_queue(slugs)
      end

      # ---------------------------------------------------------------
      # Atualização da própria Central K — não mexe em @last_state de
      # produto nenhum, por isso usa uma trava própria (:central_k_update)
      # e pode rodar independente de bootstrap/instalação.
      # ---------------------------------------------------------------

      # Assim que a Central abre e o servidor informa versão nova, ela se atualiza sozinha
      # (uma tentativa por versão a cada sessão do SketchUp). O botão continua como reserva.
      def auto_update_central_k
        info = central_k_update_info(last_state['central_k'])
        return unless info['available']
        return if @install_busy || @central_update_busy
        return if @central_auto_attempted == info['version']

        @central_auto_attempted = info['version']
        @central_update_silent = true
        update_central_k
      rescue StandardError => error
        warn("[Central K] Autoatualização automática: #{error.class}: #{error.message}")
      end

      def update_central_k
        info = central_k_update_info(last_state['central_k'])
        unless info['available']
          render_state(current_authenticated_payload('Nenhuma atualização disponível.'))
          return
        end
        if @install_busy
          render_state(current_authenticated_payload('Aguarde a instalação dos plugins terminar antes de atualizar a Central K.'))
          return
        end
        if @central_update_busy
          render_state(current_authenticated_payload('A atualização da Central K já está em andamento…'))
          return
        end
        @central_update_busy = true
        @central_update_generation = (@central_update_generation || 0) + 1
        render_state(current_authenticated_payload('Baixando a atualização da Central K…'))
        download_central_k_native(last_state['central_k'], info, @central_update_generation)
      end

      def download_central_k_native(central_k, info, generation, attempt = 0)
        request = Sketchup::Http::Request.new(central_k['download_url'].to_s, Sketchup::Http::GET)
        request.headers = { 'Accept' => 'application/octet-stream' }
        @central_http_request = request
        @central_timeout_timer = UI.start_timer(DOWNLOAD_ATTEMPT_TIMEOUT, false) do
          next unless generation == @central_update_generation && @central_http_request.equal?(request)
          @central_timeout_timer = nil
          @central_http_request = nil
          request.cancel rescue nil
          handle_central_download(central_k, info, generation, attempt, 0, nil)
        end
        started = request.start do |_finished_request, response|
          next unless generation == @central_update_generation && @central_http_request.equal?(request)
          UI.stop_timer(@central_timeout_timer) rescue nil if @central_timeout_timer
          @central_timeout_timer = nil
          @central_http_request = nil
          handle_central_download(central_k, info, generation, attempt,
                                  response ? response.status_code.to_i : 0,
                                  response ? response.body.to_s : nil)
        end
        unless started
          UI.stop_timer(@central_timeout_timer) rescue nil if @central_timeout_timer
          @central_timeout_timer = nil
          @central_http_request = nil
          handle_central_download(central_k, info, generation, attempt, 0, nil)
        end
      rescue StandardError => error
        warn("[Central K] Autoatualização: #{error.class}: #{error.message}")
        handle_central_download(central_k, info, generation, attempt, 0, nil)
      end

      def handle_central_download(central_k, info, generation, attempt, code, bytes)
        return unless generation == @central_update_generation
        if code.between?(200, 299) && bytes && bytes.bytesize.positive? && bytes.bytesize <= MAX_PACKAGE_BYTES
          expected_hash = central_k['sha256'].to_s.upcase
          unless Digest::SHA256.hexdigest(bytes).upcase == expected_hash
            finish_central_download_error('A atualização recebida não passou na verificação de segurança.')
            return
          end
          path = download_cache_path('central_k', expected_hash)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.tmp"
          File.open(tmp, 'wb') { |file| file.write(bytes) }
          File.rename(tmp, path)
          @central_update_busy = false
          finish_central_k_update(:ok, { ok: true, path: path }, info)
          return
        end
        if attempt < RETRY_DELAYS.length
          render_state(current_authenticated_payload("Download interrompido; tentando novamente… (#{attempt + 2} de #{RETRY_DELAYS.length + 1})"))
          @central_retry_timer = UI.start_timer(RETRY_DELAYS[attempt], false) do
            next unless generation == @central_update_generation
            @central_retry_timer = nil
            download_central_k_native(central_k, info, generation, attempt + 1)
          end
        else
          finish_central_download_error('Não foi possível baixar a atualização da Central K agora.')
        end
      rescue StandardError => error
        warn("[Central K] Cache da atualização: #{error.class}: #{error.message}")
        finish_central_download_error('Não foi possível salvar a atualização neste computador.')
      end

      def finish_central_download_error(message)
        @central_update_busy = false
        @central_update_generation = (@central_update_generation || 0) + 1
        if @central_update_silent
          # Atualização automática: sem mensagem de erro para o comprador. Tenta de novo na
          # próxima abertura da Central (ou pelo botão "Atualizar agora").
          warn("[Central K] Atualização automática não concluída: #{message}")
          @central_auto_attempted = nil
          render_state(current_authenticated_payload)
          return
        end
        render_state(current_authenticated_payload(message).merge('message_ok' => false))
      end

      def finish_central_k_update(status, result, info)
        if status == :error || !result[:ok]
          return finish_central_download_error(result.is_a?(Hash) ? result[:error] : 'Falha inesperada ao atualizar.')
        end
        begin
          installed = Sketchup.install_from_archive(result[:path], false)
          return finish_central_download_error('O SketchUp não concluiu a instalação.') unless installed
        rescue Interrupt
          return finish_central_download_error('Instalação cancelada.')
        rescue Exception => error
          return finish_central_download_error("Falha ao instalar: #{error.message}")
        end
        @central_installed_pending = info['version']
        render_state(current_authenticated_payload(restart_message))
      end

      def error_message(body)
        case body['error']
        when 'no_purchases' then 'Não encontramos compra neste e-mail. Confira o e-mail usado no checkout da Hotmart.'
        when 'device_blocked' then 'Os dois computadores permitidos já estão vinculados a este e-mail.'
        when 'device_limit_reached' then "Os dois computadores permitidos já estão vinculados a este e-mail."
        when 'not_entitled' then 'Sua conta não possui este produto. Clique em "Comprar" para adquirir.'
        when 'invalid_device' then 'Não foi possível identificar este computador. Reinicie o SketchUp e tente novamente.'
        when 'product_not_found' then 'Este plugin não foi encontrado no catálogo. Atualize a Central K e tente novamente.'
        when 'timeout', 'offline', 'server_down', 'network_error' then 'A conexão falhou; tentaremos novamente automaticamente.'
        when 'invalid_email' then 'E-mail inválido.'
        when 'invalid_token' then 'Não foi possível confirmar a autorização deste plugin. Tente de novo.'
        else body['message'] || body['error'] || 'Não foi possível concluir.'
        end
      end

      def reason_for(body)
        case body['error']
        when 'no_purchases' then 'no_purchases'
        when 'device_limit_reached', 'device_blocked' then 'device_limit'
        else 'error'
        end
      end

      def central_k_update_info(central_k)
        central_k ||= {}
        version = central_k['version'].to_s
        url = central_k['download_url'].to_s
        sha256 = central_k['sha256'].to_s
        # Já instalada nesta sessão (falta só reiniciar): não baixa de novo.
        baseline = @central_installed_pending && newer_version?(@central_installed_pending, CENTRAL_K_VERSION) ? @central_installed_pending : CENTRAL_K_VERSION
        available = !version.empty? && newer_version?(version, baseline) &&
                    url.start_with?('https://') && sha256.match?(/\A[A-Fa-f0-9]{64}\z/)
        { 'available' => available, 'version' => version, 'current_version' => CENTRAL_K_VERSION }
      end

      def restart_message
        "Central K atualizada para a versão #{@central_installed_pending}. Feche e abra o SketchUp de novo pra usar."
      end

      # ---------------------------------------------------------------
      # Renovação inteligente das autorizações
      # ---------------------------------------------------------------

      # Só lê arquivos locais. true quando alguma autorização de plugin vence em até 2 dias.
      def renewal_due?
        limit = Time.now.to_i + RENEW_BEFORE_SECONDS
        Dir.glob(File.join(data_dir, 'licenses', '*.json')).any? do |path|
          exp = TokenVerify.peek_exp(read_json(path)['token'])
          exp.is_a?(Integer) && exp < limit
        end
      rescue StandardError
        false
      end

      # ---------------------------------------------------------------
      # Vitrine atualizável (ui.html + media/)
      #
      # O servidor informa, na mesma resposta do bootstrap, a versão da vitrine publicada e
      # o endereço do seu índice (manifest.json, com o SHA-256 de cada arquivo). Se for
      # diferente da vitrine em uso, a Central baixa em segundo plano só os arquivos que
      # ainda não tem, confere cada um e troca a vitrine. Qualquer falha é silenciosa para o
      # comprador: a vitrine atual continua, o motivo vai só para o Console Ruby e a mesma
      # versão não é tentada de novo nesta sessão.
      # ---------------------------------------------------------------

      def ui_root
        File.join(data_dir, 'ui')
      end

      def ui_state_path
        File.join(ui_root, 'current.json')
      end

      # Vitrine baixada em uso, se estiver íntegra e for compatível com este código.
      def installed_ui
        state = read_json(ui_state_path)
        dir = state['dir'].to_s
        return nil if dir.empty? || !File.file?(File.join(dir, 'ui.html'))
        return nil unless File.expand_path(dir).start_with?(File.expand_path(ui_root) + '/')
        return nil if newer_version?(state['min_central_version'], CENTRAL_K_VERSION)
        state
      rescue StandardError
        nil
      end

      def ui_version_in_use
        (installed_ui || {})['version'] || UI_BUNDLED_VERSION
      end

      def ui_url
        ui = installed_ui
        file = ui ? File.join(ui['dir'], 'ui.html') : File.join(ASSET_DIR, 'ui.html')
        "file:///#{file.gsub('\\', '/')}?v=#{Time.now.to_i}"
      end

      def maybe_update_vitrine(central_k)
        central_k ||= {}
        version = central_k['ui_version'].to_s.strip
        manifest_url = central_k['ui_manifest_url'].to_s
        manifest_sha = central_k['ui_manifest_sha256'].to_s.upcase
        return if version.empty? || version == ui_version_in_use
        return if @ui_update_busy || @ui_skipped_versions.to_a.include?(version)
        return unless manifest_url.start_with?('https://') && manifest_sha.match?(/\A[A-F0-9]{64}\z/)

        @ui_update_busy = true
        @ui_generation = (@ui_generation || 0) + 1
        generation = @ui_generation
        ui_http_get(manifest_url, 64 * 1024 * 16, generation) do |bytes|
          next vitrine_failed(version, 'índice não baixado') unless bytes
          next vitrine_failed(version, 'índice não confere') unless Digest::SHA256.hexdigest(bytes).upcase == manifest_sha

          manifest = JSON.parse(bytes.force_encoding('UTF-8')) rescue nil
          files = manifest.is_a?(Hash) ? manifest['files'] : nil
          next vitrine_failed(version, 'índice inválido') unless files.is_a?(Array) && manifest['version'].to_s == version
          if newer_version?(manifest['min_central_version'], CENTRAL_K_VERSION)
            # Precisa de uma Central mais nova: fica para depois da atualização do código.
            next vitrine_failed(version, "requer Central #{manifest['min_central_version']}")
          end

          entries = validate_ui_files(files)
          next vitrine_failed(version, 'lista de arquivos inválida') unless entries

          fetch_ui_files(entries, generation) do |ok|
            next vitrine_failed(version, 'arquivos não baixados') unless ok

            activate_vitrine(version, manifest['min_central_version'].to_s, entries)
          end
        end
      rescue StandardError => error
        vitrine_failed(version, "#{error.class}: #{error.message}")
      end

      def validate_ui_files(files)
        return nil if files.empty? || files.length > MAX_UI_FILES

        entries = files.map do |item|
          return nil unless item.is_a?(Hash)

          path = item['path'].to_s
          sha = item['sha256'].to_s.upcase
          url = item['url'].to_s
          size = item['size'].to_i
          return nil unless path.match?(UI_SAFE_PATH) && sha.match?(/\A[A-F0-9]{64}\z/) && url.start_with?('https://')
          return nil unless size.positive? && size <= MAX_UI_FILE_BYTES

          { path: path, sha256: sha, url: url, size: size }
        end
        entries.any? { |entry| entry[:path] == 'ui.html' } ? entries : nil
      end

      # Arquivos guardados pelo conteúdo (SHA-256): um arquivo igual nunca é baixado duas vezes.
      def ui_store_path(sha)
        File.join(ui_root, 'files', sha.downcase)
      end

      def ui_file_ready?(entry)
        path = ui_store_path(entry[:sha256])
        return true if File.file?(path) && File.size(path) == entry[:size]

        # Igual ao que já veio neste pacote: copia em vez de baixar.
        bundled = File.join(ASSET_DIR, entry[:path])
        if File.file?(bundled) && File.size(bundled) == entry[:size] && Digest::SHA256.file(bundled).hexdigest.upcase == entry[:sha256]
          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.cp(bundled, path)
          return true
        end
        false
      end

      def fetch_ui_files(entries, generation, &done)
        pending = entries.reject { |entry| ui_file_ready?(entry) }
        download_next_ui_file(pending, generation, &done)
      rescue StandardError => error
        warn("[Central K] Vitrine: #{error.class}: #{error.message}")
        done.call(false)
      end

      # Um arquivo por vez, para não disputar a conexão com o resto da Central.
      def download_next_ui_file(pending, generation, &done)
        return unless generation == @ui_generation

        entry = pending.shift
        return done.call(true) unless entry

        ui_http_get(entry[:url], entry[:size], generation) do |bytes|
          if bytes && bytes.bytesize == entry[:size] && Digest::SHA256.hexdigest(bytes).upcase == entry[:sha256]
            path = ui_store_path(entry[:sha256])
            FileUtils.mkdir_p(File.dirname(path))
            File.open("#{path}.tmp", 'wb') { |file| file.write(bytes) }
            File.rename("#{path}.tmp", path)
            download_next_ui_file(pending, generation, &done)
          else
            done.call(false)
          end
        end
      rescue StandardError => error
        warn("[Central K] Vitrine: #{error.class}: #{error.message}")
        done.call(false)
      end

      # GET nativo do SketchUp (assíncrono: não trava o SketchUp). Chama o bloco com os bytes
      # ou nil. Sem novas tentativas: se falhar, fica para a próxima abertura da Central.
      def ui_http_get(url, max_bytes, generation, &complete)
        request = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
        request.headers = { 'Accept' => '*/*' }
        @ui_http_request = request
        timeout = DOWNLOAD_ATTEMPT_TIMEOUT + (max_bytes / (150 * 1024))
        finished = false
        finish = lambda do |bytes|
          next if finished

          finished = true
          UI.stop_timer(@ui_timeout_timer) rescue nil if @ui_timeout_timer
          @ui_timeout_timer = nil
          @ui_http_request = nil
          complete.call(bytes) if generation == @ui_generation
        end
        @ui_timeout_timer = UI.start_timer(timeout, false) do
          request.cancel rescue nil
          finish.call(nil)
        end
        started = request.start do |_request, response|
          code = response ? response.status_code.to_i : 0
          body = response ? response.body.to_s : nil
          ok = code.between?(200, 299) && body && body.bytesize.positive? && body.bytesize <= max_bytes
          finish.call(ok ? body : nil)
        end
        finish.call(nil) unless started
      rescue StandardError => error
        warn("[Central K] Vitrine (rede): #{error.class}: #{error.message}")
        finish ? finish.call(nil) : complete.call(nil)
      end

      def activate_vitrine(version, min_central, entries)
        dir = File.join(ui_root, "v-#{version.gsub(/[^0-9A-Za-z._-]/, '_')}-#{Time.now.to_i}")
        entries.each do |entry|
          target = File.join(dir, entry[:path])
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(ui_store_path(entry[:sha256]), target)
        end
        previous = installed_ui
        write_json(ui_state_path, { 'version' => version, 'dir' => dir, 'min_central_version' => min_central })
        cleanup_old_vitrines(dir, entries)
        @ui_update_busy = false
        warn("[Central K] Vitrine #{version} instalada.")
        reload_dialog_with_vitrine unless previous && previous['dir'] == dir
      rescue StandardError => error
        vitrine_failed(version, "#{error.class}: #{error.message}")
      end

      # Mantém só a vitrine em uso e os arquivos que ela usa (não acumula versões antigas).
      def cleanup_old_vitrines(current_dir, entries)
        keep = entries.map { |entry| entry[:sha256].downcase }.to_set
        Dir.glob(File.join(ui_root, 'v-*')).each do |dir|
          FileUtils.rm_rf(dir) unless File.expand_path(dir) == File.expand_path(current_dir)
        end
        Dir.glob(File.join(ui_root, 'files', '*')).each do |path|
          File.delete(path) unless keep.include?(File.basename(path))
        end
      rescue StandardError => error
        warn("[Central K] Limpeza da vitrine: #{error.class}: #{error.message}")
      end

      # Troca a vitrine na janela aberta, a menos que uma instalação esteja em andamento
      # (nesse caso ela já aparece na próxima abertura).
      def reload_dialog_with_vitrine
        return unless @dialog && @dialog.visible?
        return if @install_busy || @central_update_busy

        @dialog.set_url(ui_url)
      rescue StandardError => error
        warn("[Central K] Recarregar vitrine: #{error.class}: #{error.message}")
      end

      def vitrine_failed(version, reason)
        @ui_update_busy = false
        (@ui_skipped_versions ||= []) << version.to_s
        warn("[Central K] Vitrine #{version} não aplicada: #{reason}. Continua a vitrine atual.")
        nil
      end

      # ---------------------------------------------------------------
      # UI
      # ---------------------------------------------------------------

      # `render_state` só entrega um payload já pronto pra UI — nunca
      # dispara requisição nova (ponto 1 do plano). Quem precisa de dado
      # novo do servidor chama `request_state`.
      def render_state(payload)
        return unless @dialog && @dialog.visible?
        @dialog.execute_script("window.renderState(#{JSON.generate(payload)});")
      end

      def open
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          request_state
          return
        end

        @dialog = UI::HtmlDialog.new(
          dialog_title: 'Central K-Plugins',
          preferences_key: 'KahDetalha.CentralKPilot',
          scrollable: true,
          resizable: true,
          width: 760,
          height: 640,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_url(ui_url)
        @dialog.center

        @dialog.add_action_callback('ready') { |_ctx| request_state }
        @dialog.add_action_callback('refresh') { |_ctx| request_state }

        @dialog.add_action_callback('enter') do |_ctx, raw|
          data = JSON.parse(raw.to_s)
          email = data['email'].to_s.strip.downcase
          if email !~ EMAIL_RE
            @dialog.execute_script("window.showMessage(#{JSON.generate('Informe um e-mail válido.')}, false);")
          else
            save_email(email)
            request_state
          end
        end

        @dialog.add_action_callback('logout') do |_ctx|
          cancel_install_network
          clear_session
          @last_state = {}
          render_state({ 'authenticated' => false, 'message' => 'Sessão encerrada.' })
        end

        @dialog.add_action_callback('activate') do |_ctx, slug|
          install_product(slug.to_s)
        end

        @dialog.add_action_callback('install') do |_ctx, slug|
          install_product(slug.to_s)
        end

        @dialog.add_action_callback('updateAll') { |_ctx| update_all }
        @dialog.add_action_callback('updateCentralK') do |_ctx|
          @central_update_silent = false # clique do comprador: mostra o resultado, inclusive falhas
          update_central_k
        end

        # A desativação de dispositivo pelo cliente foi removida (item 5
        # do plano) — troca de máquina passa a ser só administrativa.

        @dialog.add_action_callback('openCheckout') do |_ctx, url|
          UI.openURL(url.to_s) if url.to_s.start_with?('https://')
        end

        @dialog.show
        # Não chama request_state aqui: o próprio ui.html dispara 'ready'
        # no DOMContentLoaded, que já cai em request_state.
      end
    end

    unless file_loaded?('central_k_pilot/main')
      begin
        UI.menu('Extensions').add_item('Central K-Plugins') { CentralKPilot.open }
      rescue Exception => error
        warn("[Central K-Plugins] Falha ao criar o menu: #{error.class}: #{error.message}")
      end

      begin
        cmd = UI::Command.new('Central K-Plugins') { CentralKPilot.open }
        cmd.tooltip = 'Central K-Plugins'
        cmd.status_bar_text = 'Abrir a Central K-Plugins'
        icon_dir = File.join(ASSET_DIR, 'toolbar')
        cmd.small_icon = File.join(icon_dir, 'icon_24.png')
        cmd.large_icon = File.join(icon_dir, 'icon_32.png')
        toolbar = UI::Toolbar.new('Central K-Plugins')
        toolbar.add_item(cmd)
        toolbar.show
      rescue Exception => error
        warn("[Central K-Plugins] Falha ao criar a toolbar: #{error.class}: #{error.message}")
      end

      # A Central nunca abre sozinha. O comprador escolhe quando acessá-la
      # pelo botão da barra de ferramentas ou pelo menu Extensões.
      # A primeira consulta acontece somente quando a janela da Central é
      # aberta (callback `ready`). Evita uma consulta invisível no boot do
      # SketchUp concorrer com a consulta solicitada pelo cliente.
      # Verificação local a cada 30 min; o servidor só é consultado quando alguma autorização
      # de plugin vence em até 2 dias (antes: consulta a cada 30 min, sempre).
      # Ao abrir o SketchUp: atualização automática dos plugins comprados (sem abrir a Central).
      UI.start_timer(STARTUP_CHECK_DELAY, false) do
        CentralKPilot.startup_check
      end

      UI.start_timer(RENEW_CHECK_SECONDS, true) do
        begin
          CentralKPilot.request_state if !CentralKPilot.saved_email.empty? && CentralKPilot.renewal_due?
        rescue StandardError => error
          warn("[Central K] Renovação: #{error.class}: #{error.message}")
        end
      end

      file_loaded('central_k_pilot/main')
    end
  end
end
