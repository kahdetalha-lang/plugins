# frozen_string_literal: true

# PUBLICADOR DA CENTRAL K — uso exclusivo da administração. NÃO vai dentro do .rbz do comprador.
#
# Roda no Console Ruby do SketchUp (Janela › Console Ruby):
#
#   load 'C:/caminho/publicador_central_k.rb'
#
#   # Vitrine (textos, cards, imagens, categorias, layout): aparece para o comprador na
#   # próxima vez que ele abrir a Central, sem reinstalar nada.
#   PublicadorCentralK.vitrine('C:/caminho/pasta_da_vitrine', '1.0.2', 'SEU_TOKEN_ADMIN')
#
#   # Código da Central (.rbz JÁ ASSINADO na Trimble): a Central do comprador se atualiza
#   # sozinha ao abrir e pede para reiniciar o SketchUp.
#   PublicadorCentralK.central('C:/caminho/Central_K_1.0.2.rbz', '1.0.2', 'SEU_TOKEN_ADMIN')
#
#   # Plugin (.rbz JÁ ASSINADO): nova versão de um plugin do catálogo (ex.: revest, klight,
#   # kcenas). Aparece na Central como atualização / instalação disponível.
#   PublicadorCentralK.plugin('revest', 'C:/caminho/REVEST_v1.0.1.rbz', '1.0.1', 'SEU_TOKEN_ADMIN')
#
# A pasta da vitrine é a mesma estrutura de dentro do plugin: ui.html + media/...
# O token é o valor de "admin_upload_token" no ck_config do Supabase.
#
# Cada arquivo sobe com o nome do seu SHA-256: publicar de novo não duplica imagens iguais,
# e a Central do comprador baixa só o que mudou.

require 'json'
require 'digest'
require 'base64'
require 'time'

module PublicadorCentralK
  FUNCTION_URL = 'https://flibbkyxitkvsdnmgrcl.supabase.co/functions/v1/admin-upload-package'
  PUBLIC_BASE = 'https://flibbkyxitkvsdnmgrcl.supabase.co/storage/v1/object/public/packages/'
  PUBLISHABLE_KEY = 'sb_publishable__yTAPKcnYXFCKDV2vPv1rg_SUGyWvYv'
  # Mesma regra de caminho que a Central aceita.
  SAFE_PATH = %r{\A(?!.*\.\.)[A-Za-z0-9_\-][A-Za-z0-9_\-./ ]{0,180}\z}
  MAX_FILE_BYTES = 40 * 1024 * 1024
  IGNORE = %w[Thumbs.db .DS_Store desktop.ini].freeze

  module_function

  def vitrine(folder, version, token, min_central_version: '1.0.1')
    folder = File.expand_path(folder)
    raise "Pasta não encontrada: #{folder}" unless File.directory?(folder)
    raise 'A pasta precisa ter o ui.html na raiz.' unless File.file?(File.join(folder, 'ui.html'))

    version = check_version(version)
    files = Dir.glob(File.join(folder, '**', '*')).select { |path| File.file?(path) }
    files.reject! { |path| IGNORE.include?(File.basename(path)) }
    entries = files.map do |path|
      relative = path.sub(%r{\A#{Regexp.escape(folder)}/}, '')
      raise "Nome de arquivo não permitido (use letras, números, - _ . /): #{relative}" unless relative.match?(SAFE_PATH)

      bytes = File.binread(path)
      raise "Arquivo grande demais (máx. 40 MB): #{relative}" if bytes.bytesize > MAX_FILE_BYTES

      sha = Digest::SHA256.hexdigest(bytes).upcase
      ext = File.extname(relative).downcase.gsub(/[^a-z0-9.]/, '')
      { path: relative, bytes: bytes, sha256: sha, storage: "central-ui/files/#{sha.downcase}#{ext}" }
    end
    manifest = JSON.pretty_generate(
      'version' => version, 'min_central_version' => min_central_version.to_s,
      'published_at' => Time.now.utc.iso8601,
      'files' => entries.map do |e|
        { 'path' => e[:path], 'sha256' => e[:sha256], 'size' => e[:bytes].bytesize, 'url' => PUBLIC_BASE + e[:storage] }
      end
    )
    manifest_path = "central-ui/#{version}/manifest.json"
    uploads = entries.map { |e| [e[:storage], e[:bytes]] } + [[manifest_path, manifest]]
    config = {
      'central_k_ui_version' => version,
      'central_k_ui_manifest_url' => PUBLIC_BASE + manifest_path,
      'central_k_ui_manifest_sha256' => Digest::SHA256.hexdigest(manifest).upcase
    }
    say "Vitrine #{version}: #{entries.length} arquivos. Enviando…"
    run(uploads, config, token) { say "PRONTO. Vitrine #{version} publicada: os compradores veem na próxima vez que abrirem a Central." }
  end

  def central(rbz_path, version, token)
    rbz_path = File.expand_path(rbz_path)
    raise "Arquivo não encontrado: #{rbz_path}" unless File.file?(rbz_path)
    raise 'Envie o arquivo .rbz (assinado na Trimble).' unless File.extname(rbz_path).casecmp?('.rbz')

    version = check_version(version)
    bytes = File.binread(rbz_path)
    storage = "Central_K_#{version}.rbz"
    config = {
      'central_k_version' => version,
      'central_k_download_url' => PUBLIC_BASE + storage,
      'central_k_sha256' => Digest::SHA256.hexdigest(bytes).upcase
    }
    say "Central #{version}: enviando #{(bytes.bytesize / 1048576.0).round(2)} MB…"
    run([[storage, bytes]], config, token) { say "PRONTO. Central #{version} publicada: os compradores atualizam ao abrir a Central." }
  end

  # ativar: true também liga o produto no catálogo (primeira publicação de um plugin novo).
  def plugin(slug, rbz_path, version, token, ativar: false)
    slug = slug.to_s.strip.downcase
    raise 'Slug inválido (ex.: revest, klight, kcenas).' unless slug.match?(/\A[a-z0-9_]+\z/)

    rbz_path = File.expand_path(rbz_path)
    raise "Arquivo não encontrado: #{rbz_path}" unless File.file?(rbz_path)
    raise 'Envie o arquivo .rbz (assinado na Trimble).' unless File.extname(rbz_path).casecmp?('.rbz')

    version = check_version(version)
    bytes = File.binread(rbz_path)
    storage = "#{slug}/#{slug}_#{version}.rbz"
    product = {
      'slug' => slug, 'current_version' => version,
      'download_url' => PUBLIC_BASE + storage, 'download_sha256' => Digest::SHA256.hexdigest(bytes).upcase
    }
    product['active'] = true if ativar
    say "#{slug} #{version}: enviando #{(bytes.bytesize / 1048576.0).round(2)} MB…"
    run([[storage, bytes]], nil, token, product: product) do
      say "PRONTO. #{slug} #{version} publicado: aparece na Central dos compradores na próxima abertura."
    end
  end

  # ---------------------------------------------------------------------------

  def check_version(version)
    value = version.to_s.strip
    raise 'Versão inválida. Use algo como 1.0.2' unless value.match?(/\A\d+(\.\d+){1,3}([-.][A-Za-z0-9]+)?\z/)

    value
  end

  # Sobe os arquivos um por um e, só se TODOS subirem, grava a nova versão no ck_config.
  # Se algo falhar no meio, nada muda para os compradores.
  def run(uploads, config, token, product: nil, &done)
    queue = uploads.dup
    step = lambda do
      item = queue.shift
      unless item
        final = product ? { 'token' => token, 'product' => product } : { 'token' => token, 'config' => config }
        post(final) do |ok, message|
          ok ? done.call : say("ERRO ao gravar a versão no Supabase: #{message}. Nada foi alterado para os compradores.")
        end
        next
      end
      path, bytes = item
      say "  enviando #{path} (#{(bytes.bytesize / 1024.0).round} KB)…"
      post({ 'token' => token, 'path' => path, 'content_base64' => Base64.strict_encode64(bytes) }) do |ok, message|
        ok ? step.call : say("ERRO ao enviar #{path}: #{message}. Nada foi alterado para os compradores.")
      end
    end
    step.call
    nil
  end

  def post(payload, &complete)
    request = Sketchup::Http::Request.new(FUNCTION_URL, Sketchup::Http::POST)
    request.headers = { 'Content-Type' => 'application/json', 'apikey' => PUBLISHABLE_KEY }
    request.body = JSON.generate(payload)
    @requests ||= []
    @requests << request # referência forte até o fim (a API cancela se o objeto for coletado)
    request.start do |_request, response|
      @requests.delete(request)
      code = response ? response.status_code.to_i : 0
      body = (JSON.parse(response.body.to_s) rescue {}) if response
      if code.between?(200, 299)
        complete.call(true, nil)
      else
        message = body.is_a?(Hash) && body['error'] ? body['error'] : "HTTP #{code}"
        message = 'token inválido' if message == 'invalid_token'
        complete.call(false, message)
      end
    end
  end

  def say(text)
    puts "[Publicador Central K] #{text}"
  end
end

puts '[Publicador Central K] Carregado. Use PublicadorCentralK.vitrine(...) ou PublicadorCentralK.central(...).'
