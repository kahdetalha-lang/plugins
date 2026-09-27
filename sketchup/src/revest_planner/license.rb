# frozen_string_literal: true

require 'json'
require 'digest'
require 'openssl'
require 'base64'
require 'socket'

module RevestPlanner
  # Trava de licença: o REVEST só abre com uma autorização emitida pela Central K-Plugins para
  # ESTE produto e ESTE computador. A autorização é assinada no servidor (Supabase) com uma chave
  # privada que nunca sai de lá; aqui existe só a chave pública, que serve apenas para conferir.
  # Copiar o .rbz para outra pessoa não adianta: sem a compra e a ativação no computador dela,
  # não há autorização válida. A Central renova a autorização sozinha (ela vence em 7 dias).
  module License
    PRODUCT_SLUG = 'revest'
    MAX_TOKEN_BYTES = 8 * 1024

    # Mesma chave pública da Central K (kid "ck-2026-08").
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

    module_function

    # :ok, :missing, :expired, :other_device ou :invalid
    def status
      token = read_token
      return :missing if token.nil?

      payload = verified_payload(token)
      return :invalid unless payload
      return :other_device unless payload['device_hash'] == device_hash
      return :expired unless payload['exp'] > Time.now.to_i

      :ok
    rescue StandardError
      :invalid
    end

    def authorized?
      status == :ok
    end

    # Chamado ao abrir o REVEST. Com autorização válida, devolve true; senão explica o que fazer
    # e oferece abrir a Central K (que ativa ou renova a autorização).
    def authorized_or_explain
      current = status
      return true if current == :ok

      central = defined?(::KahDetalha::CentralKPilot) && ::KahDetalha::CentralKPilot.respond_to?(:open)
      message = case current
                when :expired
                  "A autorização do REVEST neste computador precisa ser renovada.\n\n" \
                  'Abra a Central K-Plugins com internet: ela renova sozinha.'
                when :other_device
                  "Este REVEST foi ativado em outro computador.\n\n" \
                  'Ative-o neste computador pela Central K-Plugins, com o e-mail usado na compra.'
                else
                  "O REVEST precisa ser ativado pela Central K-Plugins, com o e-mail usado na compra."
                end
      if central
        answer = ::UI.messagebox("#{message}\n\nAbrir a Central K-Plugins agora?", MB_YESNO)
        ::KahDetalha::CentralKPilot.open if answer == IDYES
      else
        ::UI.messagebox("#{message}\n\nInstale a Central K-Plugins (Kah Detalha) para ativar seus plugins.")
      end
      false
    rescue StandardError => error
      puts "REVEST: verificação de licença falhou (#{error.class})."
      false
    end

    # ---------------------------------------------------------------------------

    def data_dir
      base = ENV['LOCALAPPDATA'].to_s
      base = ENV['APPDATA'].to_s if base.empty?
      base = File.expand_path('~') if base.empty?
      File.join(base, 'KahDetalha', 'CentralKPilot')
    end

    def read_token
      path = File.join(data_dir, 'licenses', "#{PRODUCT_SLUG}.json")
      return nil unless File.file?(path)

      token = JSON.parse(File.read(path, encoding: 'UTF-8'))['token'].to_s
      token.empty? || token.bytesize > MAX_TOKEN_BYTES ? nil : token
    rescue StandardError
      nil
    end

    # Confere a assinatura RS256 e a estrutura do token. Qualquer coisa fora do esperado -> nil.
    def verified_payload(token)
      parts = token.split('.')
      return nil unless parts.length == 3

      header = JSON.parse(b64url_decode(parts[0]))
      return nil unless header.is_a?(Hash) && header['alg'] == 'RS256' && header['typ'] == 'JWT'

      pem = PUBLIC_KEYS[header['kid']]
      return nil unless pem
      return nil unless OpenSSL::PKey::RSA.new(pem).verify(OpenSSL::Digest::SHA256.new, b64url_decode(parts[2]), "#{parts[0]}.#{parts[1]}")

      payload = JSON.parse(b64url_decode(parts[1]))
      return nil unless payload.is_a?(Hash) && payload['version'] == 1
      return nil unless payload['product_slug'] == PRODUCT_SLUG
      return nil unless payload['exp'].is_a?(Integer) && payload['device_hash'].is_a?(String)
      return nil unless payload['user_id'].is_a?(String) && !payload['user_id'].empty?

      payload
    rescue StandardError
      nil
    end

    def b64url_decode(value)
      text = value.to_s.tr('-_', '+/')
      text += '=' * ((4 - (text.length % 4)) % 4)
      Base64.decode64(text)
    end

    # Mesma identificação de computador da Central K (precisa bater com o que ela registra).
    def device_hash
      @device_hash ||= begin
        source = machine_source
        source = "#{Socket.gethostname}|#{ENV['USERNAME']}|#{ENV['USER']}" if source.to_s.empty?
        Digest::SHA256.hexdigest("central-k-pilot-v1|#{source}")
      end
    end

    def machine_source
      if Sketchup.platform.to_s == 'platform_win'
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
  end
end
