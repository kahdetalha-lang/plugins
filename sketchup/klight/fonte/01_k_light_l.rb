# =============================================================================
# K.Light V 1.0 — Fita LED estética no viewport do SketchUp
# Kah Detalha | kah.detalharq
#
# Este arquivo só carrega os módulos (pasta 01_k_light_l/) e registra o menu/
# toolbar. A lógica de cada tipo de luz vive em arquivos separados:
#   01_k_light_l/core.rb              — utilidades compartilhadas (tag, materiais)
#   01_k_light_l/led.rb               — fita LED (arestas e contorno de letreiro)
#   01_k_light_l/spot.rb              — spot (cone de luz)
#   01_k_light_l/letreiro.rb          — backlight (halo do letreiro)
#   01_k_light_l/ui.rb                — diálogo (HTML/JS) + editar luz selecionada
#   01_k_light_l/organic_curve_tool.rb — limpeza de linhas (Linha Contínua Orgânica)
#
# Usa `Sketchup.require` (não `load`) — é a única chamada que reconhece tanto
# .rb quanto .rbe, necessária pro pacote assinado/criptografado pelo Portal
# de Assinatura da SketchUp (só este arquivo raiz fica sem criptografia).
# =============================================================================

require 'sketchup.rb'
require 'json'

module KahDetalha
  module KLight

    PLUGIN_VERSION = '1.0.6'.freeze
    ATTR_DICT      = 'KLight'.freeze
    TAG_NAME       = 'Luzes K.Light'.freeze
    TAG_COLOR      = [252, 238, 168].freeze

    PRESETS = {
      'quente' => [255, 200,  80],
      'neutro' => [255, 250, 210],
      'frio'   => [190, 225, 255],
    }.freeze

    PRESETS_SPOT = {
      'quente' => [255, 195,  90],
      'neutro' => [255, 244, 214],
      'branca' => [255, 255, 255],
    }.freeze

    k_light_dir = File.join(File.dirname(__FILE__), '01_k_light_l')
    Sketchup.require File.join(k_light_dir, 'core')
    Sketchup.require File.join(k_light_dir, 'led')
    Sketchup.require File.join(k_light_dir, 'spot')
    Sketchup.require File.join(k_light_dir, 'letreiro')
    Sketchup.require File.join(k_light_dir, 'ui')
    Sketchup.require File.join(k_light_dir, 'organic_curve_tool')
    Sketchup.require File.join(k_light_dir, 'enhancements')

    # =========================================================================
    unless file_loaded?(__FILE__)
      begin
        ext = SketchupExtension.new('K.Light', __FILE__)
        ext.description = 'Fita LED e spot fake por camadas com alpha no viewport.'
        ext.version     = PLUGIN_VERSION
        ext.creator     = 'Kah Detalha'
        Sketchup.register_extension(ext, true)

        # Menu
        menu = UI.menu('Extensions').add_submenu('K.Light')
        menu.add_item('LED Inteligente')          { KahDetalha::KLight::Led.cmd_create_smart_led }
        menu.add_item('✦ Criar Letreiro')         { KahDetalha::KLight::Letreiro.cmd_create_backlight }
        menu.add_item('◎ Criar Spot')             { KahDetalha::KLight::Spot.cmd_create_spot }
        menu.add_item('✏ Editar Luz Selecionada') { KahDetalha::KLight.cmd_edit }
        menu.add_item('🧹 Limpeza de Linhas')     { KahDetalha::OrganicCurveTool.run }
        menu.add_item('🖌 Copiar/Colar Efeito')    { KahDetalha::KLight.start_settings_brush }
        menu.add_separator

        # Toolbar
        icons_dir = File.join(k_light_dir, 'icons')
        toolbar   = UI::Toolbar.new('K.Light')

        # --- LED INTELIGENTE ---
        # A ferramenta clássica permanece no código somente para manter
        # compatibilidade com luzes e fluxos antigos; não aparece mais na UI.
        cmd_led = UI::Command.new('K.Light — LED Inteligente') { KahDetalha::KLight::Led.cmd_create_smart_led }
        cmd_led.small_icon = File.join(icons_dir, 'k_led_24.png')
        cmd_led.large_icon = File.join(icons_dir, 'k_led_32.png')
        cmd_led.tooltip    = 'K.Light — LED Inteligente'
        cmd_led.status_bar_text = 'Passe o mouse sobre uma aresta, curva ou contorno e clique para criar'
        toolbar.add_item(cmd_led)

        cmd_backlight = UI::Command.new('K.Light — Backlight') { KahDetalha::KLight::Letreiro.cmd_create_backlight }
        cmd_backlight.small_icon = File.join(icons_dir, 'k_letreiro_24.png')
        cmd_backlight.large_icon = File.join(icons_dir, 'k_letreiro_32.png')
        cmd_backlight.tooltip    = 'K.Light — Criar letreiro (halo)'
        cmd_backlight.status_bar_text = 'Selecione as faces do letreiro e clique aqui'
        toolbar.add_item(cmd_backlight)

        # --- SPOT ---
        cmd_spot = UI::Command.new('K.Light — Spot') { KahDetalha::KLight::Spot.cmd_create_spot }
        cmd_spot.small_icon = File.join(icons_dir, 'k_spot_24.png')
        cmd_spot.large_icon = File.join(icons_dir, 'k_spot_32.png')
        cmd_spot.tooltip    = 'K.Light — Criar spot'
        cmd_spot.status_bar_text = 'Clique na face da luminária no modelo'
        toolbar.add_item(cmd_spot)

        toolbar.add_separator

        # --- EDITAR ---
        cmd_edit_tb = UI::Command.new('K.Light — Editar') { KahDetalha::KLight.cmd_edit }
        cmd_edit_tb.small_icon = File.join(icons_dir, 'k_edit_24.png')
        cmd_edit_tb.large_icon = File.join(icons_dir, 'k_edit_32.png')
        cmd_edit_tb.tooltip    = 'K.Light — Editar luz selecionada'
        cmd_edit_tb.status_bar_text = 'Selecione um grupo K.Light para editar'
        toolbar.add_item(cmd_edit_tb)

        # --- COPIAR/COLAR CONFIGURAÇÕES (conta-gotas → balde) ---
        cmd_settings = UI::Command.new('K.Light — Copiar/Colar Configurações') {
          KahDetalha::KLight.start_settings_brush
        }
        cmd_settings.small_icon = File.join(icons_dir, 'k_settings_copy_24.png')
        cmd_settings.large_icon = File.join(icons_dir, 'k_settings_copy_32.png')
        cmd_settings.tooltip = 'K.Light — Copiar/Colar Configurações'
        cmd_settings.status_bar_text = 'Clique numa luz de referência e depois nas luzes que receberão as configurações'
        toolbar.add_item(cmd_settings)
        KahDetalha::KLight.register_settings_brush_command(cmd_settings, icons_dir)

        # --- LIMPEZA DE LINHAS ---
        cmd_cleanup = UI::Command.new('K.Light — Limpeza de Linhas') { KahDetalha::OrganicCurveTool.run }
        cmd_cleanup.small_icon = File.join(icons_dir, 'k_broom_24.png')
        cmd_cleanup.large_icon = File.join(icons_dir, 'k_broom_32.png')
        cmd_cleanup.tooltip    = 'K.Light — Limpeza de Linhas'
        cmd_cleanup.status_bar_text = 'Selecione arestas quebradas/complexas e clique aqui antes de gerar o LED'
        toolbar.add_item(cmd_cleanup)

        toolbar.restore

        # Duplo clique em qualquer luz K.Light abre o editor correspondente.
        KahDetalha::KLight.install_double_click_edit

        file_loaded(__FILE__)
      rescue => err
        UI.messagebox("K.Light: erro ao carregar a extensão.\n#{err.message}")
      end
    end

  end
end
