# frozen_string_literal: true
# Testes do atualizador da Central K (fora do SketchUp, com o sistema de arquivos real).
require 'json'
require 'openssl'
require 'base64'
require 'fileutils'
require 'digest'
require 'tmpdir'

module Sketchup
  class AppObserver; end
end

KEY = OpenSSL::PKey::RSA.new(2048)
module KahDetalha
  module CentralKPilot
    module TokenVerify
      PUBLIC_KEYS = { 'test' => KEY.public_key.to_pem }.freeze
      def self.b64url_decode(str)
        str = str.to_s.tr('-_', '+/')
        Base64.decode64(str + '=' * ((4 - str.length % 4) % 4))
      end
    end
  end
end
load '/home/user/plugins/sketchup/central-k/src/central_k_pilot/updater.rb'
U = KahDetalha::CentralKPilot::Updater
class PowerLoss < Exception; end # não é StandardError: simula o processo morrendo

class FakeEnv
  attr_accessor :root, :exts, :api, :downloads, :quit_blocks, :clock, :logged
  def initialize(root)
    @root = root; @exts = []; @api = nil; @downloads = {}; @quit_blocks = []; @clock = 1_800_000_000; @logged = true
  end
  def plugins_dir = File.join(root, 'SketchUp', 'Plugins')
  def data_dir = File.join(root, 'Local', 'CentralK')
  def now = @clock
  def sketchup_version = '24.0.553'
  def sketchup_major = 24
  def platform = 'win'
  def extensions = @exts
  def product_slugs = []
  def extension_names(slug) = { 'klight' => ['K.Light'], 'revest' => ['REVEST'] }[slug] || []
  def logged_in? = @logged
  def timer(_s, &b) = b.call
  def on_quit(&b) = @quit_blocks << b
  def api_post(_action, _payload, _timeout, &b)
    code, body = @api.respond_to?(:call) ? @api.call : @api
    b.call(code, body)
  end
  def http_get(url, _t, &b)
    code, bytes = @downloads[url] || [0, nil]
    b.call(code, bytes)
  end
end

$fails = 0
def check(label, cond)
  puts "#{cond ? '  ok ' : '  FALHOU'}  #{label}"
  $fails += 1 unless cond
end

def tree(dir)
  return [] unless File.directory?(dir)
  Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).reject { |p| p.end_with?('.') }.sort
end

def write_files(base, files)
  files.each do |rel, content|
    path = File.join(base, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end

# Monta um .rbz de verdade com o zip do sistema.
def build_rbz(dir, files, name = 'pkg.rbz')
  src = File.join(dir, "src-#{rand(1_000_000)}")
  write_files(src, files)
  out = File.join(dir, name)
  File.delete(out) if File.exist?(out)
  Dir.chdir(src) { system('zip', '-q', '-X', '-r', out, *files.keys.map { |k| k.split('/').first }.uniq) or raise 'zip' }
  File.binread(out)
end

def klight_files(version, extra = {})
  {
    '01_k_light_l.rb' => "PLUGIN_VERSION = '#{version}'.freeze\n",
    '01_k_light_l/core.rbe' => "core #{version}",
    '01_k_light_l/ui.rbe' => "ui #{version}",
    '01_k_light_l/01_k_light_l.susig' => 'sig',
    '01_k_light_l/icons/a.png' => 'png'
  }.merge(extra)
end

def sign(item)
  data = U.signing_input(item)
  sig = KEY.sign(OpenSSL::Digest::SHA256.new, data)
  item.merge('kid' => 'test', 'signature' => Base64.urlsafe_encode64(sig, padding: false))
end

URL = 'https://flibbkyxitkvsdnmgrcl.supabase.co/storage/v1/object/public/packages/klight/klight_1.0.5.rbz'
def item_for(bytes, version = '1.0.5', extra = {})
  sign({
    'slug' => 'klight', 'version' => version, 'url' => URL, 'sha256' => Digest::SHA256.hexdigest(bytes).upcase,
    'size' => bytes.bytesize, 'min_sketchup_version' => '', 'platforms' => %w[win mac],
    'install_paths' => %w[01_k_light_l.rb 01_k_light_l], 'extension_names' => ['K.Light'],
    'paused' => false, 'rollout_included' => true
  }.merge(extra))
end

# Cenário base: K.Light 1.0.4 instalado com um arquivo antigo que não existe mais na 1.0.5,
# mais coisas que NÃO podem ser tocadas (outro plugin, arquivo com nome parecido, presets).
def fresh_env(name)
  root = Dir.mktmpdir("upd-#{name}-")
  env = FakeEnv.new(root)
  plugins = env.plugins_dir
  write_files(plugins, klight_files('1.0.4', '01_k_light_l/arquivo_antigo.rb' => 'old', '01_k_light_l/main.rb' => 'old main'))
  write_files(plugins, 'revest_planner.rb' => 'x', 'revest_planner/main.rbe' => 'x',
                       '01_k_light_l_meus_presets.json' => 'NAO APAGAR', 'k_light_backup_usuario.rb' => 'NAO APAGAR')
  write_files(env.data_dir, 'licenses/klight.json' => '{"token":"t"}')
  env.exts = [{ name: 'K.Light', version: '1.0.4', path: File.join(plugins, '01_k_light_l.rb') },
              { name: 'REVEST', version: '1.0.1', path: File.join(plugins, 'revest_planner', 'main') }]
  U.instance_variable_set(:@booted, false)
  U.instance_variable_set(:@checking, false)
  U.release_session_lock
  U.env = env
  [env, root]
end

def new_session(env)
  U.release_session_lock
  U.instance_variable_set(:@booted, false)
  U.instance_variable_set(:@checking, false)
  env.quit_blocks.clear
  U.boot!
end

def quit(env) = env.quit_blocks.each(&:call)

EXPECTED_105 = (tree_files = klight_files('1.0.5').keys.flat_map { |k| parts = k.split('/'); (1..parts.length).map { |i| parts[0, i].join('/') } }.uniq.sort)

def product_tree(env)
  plugins = env.plugins_dir
  (['01_k_light_l.rb'] + tree(File.join(plugins, '01_k_light_l')).map { |p| "01_k_light_l/#{p}" } + ['01_k_light_l']).select { |p| File.exist?(File.join(plugins, p)) }.sort
end

def untouched?(env)
  p = env.plugins_dir
  File.read(File.join(p, '01_k_light_l_meus_presets.json')) == 'NAO APAGAR' &&
    File.read(File.join(p, 'k_light_backup_usuario.rb')) == 'NAO APAGAR' &&
    File.exist?(File.join(p, 'revest_planner/main.rbe')) && File.exist?(File.join(env.data_dir, 'licenses/klight.json'))
end

def old_intact?(env)
  p = env.plugins_dir
  File.read(File.join(p, '01_k_light_l/core.rbe')) == 'core 1.0.4' && File.exist?(File.join(p, '01_k_light_l/arquivo_antigo.rb'))
end

# ---------------------------------------------------------------------------
puts "\n1) Atualização normal: checagem -> preparo -> troca ao fechar -> confirmação"
env, root = fresh_env('normal')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
check('preparado em staging, instalação em uso intacta', U.product_state('klight').dig('staged', 'version') == '1.0.5' && old_intact?(env))
check('registra a última checagem', U.state['last_check_at'] == env.clock && U.state['last_check_result'] == 'staged')
quit(env)
check('após fechar: só arquivos da 1.0.5 (nenhum arquivo antigo sobrou)', product_tree(env) == EXPECTED_105)
check('outros plugins, presets, arquivos de nome parecido e licença preservados', untouched?(env))
backup = U.product_state('klight').dig('swapped', 'backup')
check('backup da versão anterior guardado até confirmar', File.directory?(backup.to_s))
env.exts[0] = env.exts[0].merge(version: '1.0.5')
new_session(env)
check('abertura seguinte confirma e remove o backup', !File.exist?(backup) && U.product_state('klight').dig('last_result', 'status') == 'updated')
env.clock += 3600
U.run_check
check('não checa de novo a cada abertura (intervalo de 24h)', U.state['last_check_at'] == env.clock - 3600)

# ---------------------------------------------------------------------------
puts "\n2) Sem internet"
env, root = fresh_env('offline')
env.api = [0, nil]
U.boot!
check('termina em silêncio como offline e registra a tentativa', U.state['last_check_result'] == 'offline' && U.state['last_check_at'] == env.clock)
check('nada mudou na instalação', old_intact?(env) && untouched?(env))
env.clock += 25 * 3600
env.api = [200, { 'enabled' => true, 'products' => [] }]
U.run_check
check('tenta de novo no próximo período', U.state['last_check_result'] == 'up_to_date')

# ---------------------------------------------------------------------------
puts "\n3) Download interrompido"
env, root = fresh_env('cut')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes.byteslice(0, bytes.bytesize / 2)]
U.boot!
check('não prepara e NÃO marca a versão como falha (tenta de novo depois)', U.product_state('klight')['staged'].nil? && U.product_state('klight')['failed'].nil?)
check('instalação intacta', old_intact?(env))
env.clock += 25 * 3600
env.downloads[URL] = [200, bytes]
U.run_check
check('no período seguinte baixa e prepara normalmente', U.product_state('klight').dig('staged', 'version') == '1.0.5')

# ---------------------------------------------------------------------------
puts "\n4) Pacotes inválidos"
{
  'assinatura do servidor errada' => ->(b) { item_for(b).merge('signature' => 'AAAA') },
  'SHA-256 diferente' => ->(b) { item_for(b, '1.0.5', 'sha256' => 'A' * 64) },
}.each do |label, make|
  env, root = fresh_env('sig')
  bytes = build_rbz(root, klight_files('1.0.5'))
  env.api = [200, { 'enabled' => true, 'products' => [make.call(bytes)] }]
  env.downloads[URL] = [200, bytes]
  U.boot!
  check("#{label}: recusado, nada instalado", U.product_state('klight')['staged'].nil? && old_intact?(env))
end
{
  'arquivo de outro produto no pacote' => klight_files('1.0.5', 'outro_plugin.rb' => 'x'),
  'sem assinatura da Trimble (.susig)' => klight_files('1.0.5').reject { |k, _| k.end_with?('.susig') },
  'versão do pacote diferente da anunciada' => klight_files('1.0.6'),
}.each do |label, files|
  env, root = fresh_env('bad')
  bytes = build_rbz(root, files)
  if label.start_with?('caminho')
    # zip do sistema normaliza "../"; grava o nome malicioso direto no arquivo
    bytes = bytes.gsub('01_k_light_l/xx/../evil.rb'.b, '01_k_light_l/xx/../evil.rb'.b)
  end
  env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
  env.downloads[URL] = [200, bytes]
  U.boot!
  failed = U.product_state('klight')['failed']
  check("#{label}: recusado e marcado para não repetir", U.product_state('klight')['staged'].nil? && failed && failed['1.0.5'] && old_intact?(env))
  env.clock += 25 * 3600
  calls = 0
  env.downloads[URL] = [200, bytes]
  orig = env.method(:http_get)
  env.define_singleton_method(:http_get) { |u, t, &b| calls += 1; orig.call(u, t, &b) }
  U.run_check
  check("#{label}: não baixa a mesma versão de novo", calls.zero?)
end
# CRC corrompido e nome malicioso, montando o zip na mão
env, root = fresh_env('crc')
bytes = build_rbz(root, klight_files('1.0.5', '01_k_light_l/dados.bin' => 'A' * 4000)).dup
idx = bytes.index('core 1.0.5'.b) || bytes.index('ui 1.0.5'.b)
stored = !idx.nil?
bytes.setbyte(idx || 200, ((bytes.getbyte(idx || 200) + 1) % 256))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
check("arquivo corrompido dentro do zip (CRC#{stored ? '' : ' aprox.'}): recusado, nada instalado", U.product_state('klight')['staged'].nil? && old_intact?(env))
env, root = fresh_env('slip')
good = build_rbz(root, klight_files('1.0.5', '01_k_light_l/abcdefghij.rb' => 'x'))
evil = good.gsub('01_k_light_l/abcdefghij.rb'.b, '01_k_light_l/../../../x.rb'.b)
env.api = [200, { 'enabled' => true, 'products' => [item_for(evil)] }]
env.downloads[URL] = [200, evil]
U.boot!
check('caminho "../" escapando da pasta: recusado, nada criado fora', U.product_state('klight')['staged'].nil? && !File.exist?(File.join(root, 'SketchUp', 'x.rb')) && old_intact?(env))

# ---------------------------------------------------------------------------
puts "\n5) Falta de espaço em disco"
env, root = fresh_env('nospace')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
class << File
  alias_method :orig_binwrite, :binwrite
  def binwrite(path, data) = path.include?('staging') ? raise(Errno::ENOSPC) : orig_binwrite(path, data)
end
U.boot!
class << File
  alias_method :binwrite, :orig_binwrite
end
check('sem espaço: nada preparado, staging limpo, instalação intacta', U.product_state('klight')['staged'].nil? && tree(File.join(U.work_root, 'staging')).empty? && old_intact?(env))
check('sem espaço: não marca como falha definitiva', U.product_state('klight')['failed'].nil? && U.product_state('klight').dig('last_result', 'status') == 'no_space')

# ---------------------------------------------------------------------------
puts "\n6) Arquivo bloqueado durante a troca"
env, root = fresh_env('locked')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
class << File
  alias_method :orig_rename, :rename
  def rename(a, b) = (a.end_with?('Plugins/01_k_light_l.rb') && $lock_on) ? raise(Errno::EACCES, a) : orig_rename(a, b)
end
$lock_on = true
3.times do |i|
  quit(env)
  check("tentativa #{i + 1}: troca desfeita, versão antiga funcionando", old_intact?(env) && File.exist?(File.join(env.plugins_dir, '01_k_light_l.rb')) && untouched?(env))
  new_session(env) if i < 2
end
ps = U.product_state('klight')
check('após 3 tentativas: para de insistir e pede para reabrir o SketchUp', ps['staged'].nil? && ps.dig('failed', '1.0.5') && ps.dig('last_result', 'status') == 'needs_restart')
$lock_on = false

# ---------------------------------------------------------------------------
puts "\n7) Instalação antiga com outro nome (descoberta pelo caminho real do plugin)"
env, root = fresh_env('legacy')
plugins = env.plugins_dir
FileUtils.rm_rf(File.join(plugins, '01_k_light_l')); File.delete(File.join(plugins, '01_k_light_l.rb'))
write_files(plugins, 'k_light.rb' => "VERSION='1.0.2'", 'k_light/main.rb' => 'old', 'k_light/velho.rb' => 'old')
env.exts[0] = { name: 'K.Light', version: '1.0.2', path: File.join(plugins, 'k_light.rb') }
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
U.instance_variable_set(:@booted, false)
quit(env)
check('instalação antiga (k_light.rb + k_light/) removida por completo', !File.exist?(File.join(plugins, 'k_light.rb')) && !File.exist?(File.join(plugins, 'k_light')))
check('nova instalação completa e nada de outro produto apagado', product_tree(env) == EXPECTED_105 && untouched?(env))

# ---------------------------------------------------------------------------
puts "\n8) Duas janelas do SketchUp abertas"
env, root = fresh_env('two')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
other = File.open(File.join(env.data_dir, 'updates', 'locks', 'session-99999-aaaaaa.lock').tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, File::RDWR | File::CREAT)
other.flock(File::LOCK_EX)
U.boot!
upd = File.open(File.join(env.data_dir, 'updates', 'locks', 'update.lock'), File::RDWR | File::CREAT)
upd.flock(File::LOCK_EX)
U.instance_variable_set(:@checking, false)
check('checagem simultânea bloqueada (outra sessão checando)', U.run_check(force: true, manual: true) == 'busy')
upd.flock(File::LOCK_UN); upd.close
quit(env)
check('com a outra janela aberta, a troca espera (nada alterado)', old_intact?(env) && U.product_state('klight').dig('staged', 'version') == '1.0.5')
other.flock(File::LOCK_UN); other.close
new_session(env)
quit(env)
check('quando a última janela fecha, a troca acontece', product_tree(env) == EXPECTED_105)

# ---------------------------------------------------------------------------
puts "\n9) Queda de energia no meio da troca (em cada etapa)"
total_moves = nil
(1..4).each do |cut_after|
  env, root = fresh_env("power#{cut_after}")
  bytes = build_rbz(root, klight_files('1.0.5'))
  env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
  env.downloads[URL] = [200, bytes]
  U.boot!
  n = 0
  class << U
    alias_method :orig_move_path, :move_path
  end
  U.define_singleton_method(:move_path) { |a, b| n += 1; orig_move_path(a, b); raise PowerLoss if n == $cut }
  $cut = cut_after
  begin
    quit(env)
  rescue PowerLoss
    nil
  end
  U.singleton_class.send(:alias_method, :move_path, :orig_move_path)
  interrupted = File.exist?(U.journal_path)
  env.exts[0] = env.exts[0].merge(version: '1.0.5') unless interrupted # a troca terminou: o SketchUp carrega a nova
  new_session(env) # abertura seguinte: recupera
  restored = old_intact?(env) && untouched?(env) && !File.exist?(U.journal_path)
  quit(env)
  env.exts[0] = env.exts[0].merge(version: '1.0.5')
  new_session(env)
  done = product_tree(env) == EXPECTED_105 && untouched?(env) && U.product_state('klight')['swapped'].nil?
  check("corte após o movimento #{cut_after}#{interrupted ? '' : ' (troca já tinha terminado)'}: #{interrupted ? 'versão anterior restaurada, ' : ''}depois concluída sem sobras", (interrupted ? restored : true) && done)
end

# ---------------------------------------------------------------------------
puts "\n10) Nova versão não carrega -> volta para a anterior"
env, root = fresh_env('revert')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
quit(env)
env.exts[0] = env.exts[0].merge(version: '1.0.4') # SketchUp não carregou a nova
new_session(env)
quit(env)
check('versão anterior restaurada por completo', old_intact?(env) && untouched?(env))
check('versão que falhou não é reinstalada', U.product_state('klight').dig('failed', '1.0.5'))
env.clock += 25 * 3600
new_session(env)
check('na checagem seguinte não prepara de novo', U.product_state('klight')['staged'].nil?)

# ---------------------------------------------------------------------------
puts "\n11) Controle de publicação"
env, root = fresh_env('ctl')
bytes = build_rbz(root, klight_files('1.0.3'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes, '1.0.3')] }]
env.downloads[URL] = [200, bytes]
U.boot!
check('nunca instala versão inferior', U.product_state('klight')['staged'].nil?)
env, root = fresh_env('rollout')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes, '1.0.5', 'rollout_included' => false)] }]
env.downloads[URL] = [200, bytes]
U.boot!
check('fora do grupo inicial: não atualiza automaticamente', U.product_state('klight')['staged'].nil?)
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.clock += 25 * 3600
U.run_check
check('entrou no grupo: prepara', U.product_state('klight').dig('staged', 'version') == '1.0.5')
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes, '1.0.5', 'paused' => true)] }]
U.run_check(force: true, manual: true)
check('suspensa remotamente: preparo cancelado', U.product_state('klight')['staged'].nil?)
quit(env)
check('suspensa: nada trocado ao fechar', old_intact?(env))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
U.run_check(force: true, manual: true)
env.api = [200, { 'enabled' => false, 'products' => [] }]
U.run_check(force: true, manual: true)
check('desligada no servidor: preparo cancelado', U.product_state('klight')['staged'].nil?)
env, root = fresh_env('compat')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes, '1.0.5', 'min_sketchup_version' => '2030')] }]
env.downloads[URL] = [200, bytes]
U.boot!
check('incompatível com a versão do SketchUp: ignorado', U.product_state('klight')['staged'].nil?)
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes, '1.0.5', 'platforms' => ['mac'])] }]
U.run_check(force: true, manual: true)
check('incompatível com o sistema operacional: ignorado', U.product_state('klight')['staged'].nil?)

# ---------------------------------------------------------------------------
puts "\n12) Plugin desinstalado pelo usuário e retenção do backup"
env, root = fresh_env('uninst')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
FileUtils.rm_rf(File.join(env.plugins_dir, '01_k_light_l')); File.delete(File.join(env.plugins_dir, '01_k_light_l.rb'))
env.exts.shift
quit(env)
check('desinstalado: não é reinstalado por conta própria', !File.exist?(File.join(env.plugins_dir, '01_k_light_l.rb')))
env, root = fresh_env('retention')
bytes = build_rbz(root, klight_files('1.0.5'))
env.api = [200, { 'enabled' => true, 'products' => [item_for(bytes)] }]
env.downloads[URL] = [200, bytes]
U.boot!
quit(env)
backup = U.product_state('klight').dig('swapped', 'backup')
env.clock += 15 * 24 * 3600
env.exts.shift # plugin não registrado (ex.: desabilitado) e arquivos presentes não importam: passou do prazo
U.cleanup_expired
check('sem confirmação em 14 dias: backup removido', !File.exist?(backup))

# ---------------------------------------------------------------------------
puts "\n13) Registro local"
log = File.read(U.log_path, encoding: 'UTF-8')
check('registro sem e-mails nem pasta do usuário', !log.match?(/@[a-z]+\./) && !log.include?(Dir.home))
check('registro pequeno', File.size(U.log_path) < U::LOG_MAX_BYTES * 2)

puts "\n#{$fails.zero? ? 'TODOS OS TESTES PASSARAM' : "#{$fails} TESTE(S) FALHARAM"}"
exit($fails.zero? ? 0 : 1)
