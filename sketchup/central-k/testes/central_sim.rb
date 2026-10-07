# frozen_string_literal: true
# Central K inteira (main.rb + updater.rb) num SketchUp simulado, sem acessar o servidor real.
require 'json'; require 'tmpdir'; require 'fileutils'; require 'openssl'; require 'base64'; require 'digest'

ROOT = Dir.mktmpdir('ck-sim-')
ENV['LOCALAPPDATA'] = File.join(ROOT, 'Local')
PLUGINS = File.join(ROOT, 'Roaming', 'SketchUp', 'Plugins')
FileUtils.mkdir_p(PLUGINS)
KL104 = '/tmp/claude-0/-home-user-plugins/a5c2d128-591b-5a4a-a025-32be6a8f99e6/scratchpad/kl104.rbz'
KL105 = '/home/user/plugins/sketchup/klight/assinado/K.Light_v1.0.5_assinado.rbz'
system('unzip', '-q', KL104, '-d', PLUGINS) or abort('unzip 1.0.4')
File.write(File.join(PLUGINS, '01_k_light_l', 'sobra_da_versao_antiga.rb'), 'old')
File.write(File.join(PLUGINS, 'meu_outro_plugin.rb'), 'NAO APAGAR')
TEST_KEY = OpenSSL::PKey::RSA.new(2048)
$ext_version = '1.0.4'
$observers = []
$http_log = []

module Sketchup
  class AppObserver; end
  Ext = Struct.new(:name, :version, :extension_path) { def loaded? = true }
  def self.platform = :platform_win
  def self.version = '24.0.553'
  def self.find_support_file(_) = PLUGINS
  def self.extensions = [Ext.new('K.Light Pilot', $ext_version, File.join(PLUGINS, '01_k_light_l.rb'))]
  def self.add_observer(o) = ($observers << o; true)
  def self.require(path) = Kernel.load("#{path}.rb")
  def self.install_from_archive(*) = raise('não deveria instalar por cima')
  module Http
    GET = 'GET'; POST = 'POST'
    Response = Struct.new(:status_code, :body)
    class Request
      attr_accessor :headers, :body
      def initialize(url, method) = (@url = url; @method = method)
      def cancel; end
      def start
        $http_log << [@method, @url.split('/').last, (JSON.parse(body)['action'] rescue nil)]
        if @method == POST
          action = JSON.parse(body)['action']
          yield self, Response.new(200, JSON.generate($responses.fetch(action)))
        else
          yield self, Response.new(200, File.binread(KL105))
        end
        true
      end
    end
  end
end
module Win32
  module Registry
    class Key
      def [](_) = '11111111-2222-3333-4444-555555555555'
    end
    HKEY_LOCAL_MACHINE = Object.new.tap { |o| def o.open(*) = yield(Key.new) }
  end
end
module UI
  $timers = {}; $tid = 0; $clock = 0.0
  def self.start_timer(secs, repeat = false, &blk)
    return 0 if repeat
    $tid += 1; $timers[$tid] = [$clock + secs.to_f, blk]; $tid
  end
  def self.stop_timer(id) = $timers.delete(id)
  def self.run_timers!
    until $timers.empty?
      id, (at, blk) = $timers.min_by { |_, v| v[0] }
      $timers.delete(id); $clock = at; blk.call
    end
  end
  def self.menu(*) = Class.new { def add_item(*); end }.new
  class Command; def initialize(*); end; def method_missing(*) = nil; end
  class Toolbar; def initialize(*); end; def method_missing(*) = nil; end
end
def file_loaded?(*) = false
def file_loaded(*) = nil
def warn(m) = puts("  console: #{m}")

module KahDetalha; module CentralKPilot; PLUGIN_ROOT = '/home/user/plugins/sketchup/central-k/src'; end; end
C = KahDetalha::CentralKPilot
# Chave de teste no lugar da chave real (só neste simulador).
$LOADED_FEATURES << 'sketchup.rb'
module Kernel
  alias_method :orig_require, :require
  def require(name) = %w[sketchup win32/registry].include?(name) ? true : orig_require(name)
end
load '/home/user/plugins/sketchup/central-k/src/central_k_pilot/main.rb'
C::TokenVerify.send(:remove_const, :PUBLIC_KEYS)
C::TokenVerify.const_set(:PUBLIC_KEYS, { 'ck-2026-08' => TEST_KEY.public_key.to_pem }.freeze)

bytes = File.binread(KL105)
item = {
  'slug' => 'klight', 'version' => '1.0.5', 'url' => 'https://flibbkyxitkvsdnmgrcl.supabase.co/storage/v1/object/public/packages/klight/klight_1.0.5.rbz',
  'sha256' => Digest::SHA256.hexdigest(bytes).upcase, 'size' => bytes.bytesize, 'min_sketchup_version' => '',
  'platforms' => %w[win mac], 'install_paths' => %w[01_k_light_l.rb 01_k_light_l], 'extension_names' => ['K.Light Pilot', 'K.Light'],
  'paused' => false, 'rollout_included' => true, 'kid' => 'ck-2026-08'
}
item['signature'] = Base64.urlsafe_encode64(TEST_KEY.sign(OpenSSL::Digest::SHA256.new, C::Updater.signing_input(item)), padding: false)
$responses = { 'updates' => { 'enabled' => true, 'products' => [item] } }

def files_of_klight
  (['01_k_light_l.rb'] + Dir.glob('**/*', base: File.join(PLUGINS, '01_k_light_l')).map { |p| "01_k_light_l/#{p}" }).sort
end
expected = `unzip -Z1 "#{KL105}"`.split("\n").reject { |l| l.end_with?('/') }.sort

ok = ->(label, cond) { puts "#{cond ? '  ok ' : '  FALHOU'}  #{label}"; $fail = true unless cond }
puts "\nCentral K simulada (sem servidor real)"
C.save_email('teste@exemplo.invalid') rescue nil
C::Updater.instance_variable_set(:@booted, false)
C::Updater.env.instance_variable_set(:@x, 1)
C::Updater.boot!   # o que acontece ao abrir o SketchUp
UI.run_timers!
st = C::Updater.state
ok.('checagem ao abrir o SketchUp usou só a consulta leve "updates"', $http_log.map(&:last).compact == ['updates'])
ok.('K.Light 1.0.5 baixado, conferido e preparado', st.dig('products', 'klight', 'staged', 'version') == '1.0.5')
ok.('instalação em uso não foi tocada', File.exist?(File.join(PLUGINS, '01_k_light_l', 'sobra_da_versao_antiga.rb')))
$observers.each(&:onQuit) # fechar o SketchUp
ok.('ao fechar: pasta do K.Light idêntica ao pacote 1.0.5, nada antigo sobrou', files_of_klight - Dir.glob('**/*/', base: PLUGINS).map { |d| d.chomp('/') } == expected)
ok.('outro plugin preservado', File.read(File.join(PLUGINS, 'meu_outro_plugin.rb')) == 'NAO APAGAR')
$ext_version = '1.0.5'
C::Updater.instance_variable_set(:@booted, false)
$http_log.clear
C::Updater.boot!   # reabrir o SketchUp
UI.run_timers!
st = C::Updater.state
ok.('reabrindo: confirmou a 1.0.5 e removeu o backup', st.dig('products', 'klight', 'swapped').nil? && st.dig('products', 'klight', 'last_result', 'status') == 'updated')
ok.('reabrindo no mesmo dia: não consultou o servidor de novo', $http_log.empty?)
payload = C::Updater.status_payload
ok.('janela da Central recebe versão instalada e última checagem', payload.dig('products', 'klight', 'installed_version') == '1.0.5' && payload['last_check_at'].to_i.positive?)
puts($fail ? "\nHÁ FALHAS" : "\nSIMULAÇÃO DA CENTRAL OK")
puts File.read(File.join(ENV["LOCALAPPDATA"], "KahDetalha", "CentralKPilot", "updates", "updater.log")) rescue puts("sem log")
puts JSON.pretty_generate(C::Updater.state) rescue nil
FileUtils.rm_rf(ROOT)
