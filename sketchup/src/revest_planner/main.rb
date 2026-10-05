# frozen_string_literal: true

# Rede de segurança: se o carregador não criou a pasta do plugin (instalação antiga ou conflito com
# outro plugin), usa a pasta padrão de Plugins do SketchUp.
module RevestPlanner
  unless const_defined?(:PLUGIN_ROOT, false)
    PLUGIN_ROOT = File.join(Sketchup.find_support_file('Plugins'), 'revest_planner')
  end
end

# Sketchup.require (sem extensão) carrega tanto .rb quanto os .rbe criptografados.
%w[
  license core
  sketchup/plane_frame sketchup/face_adapter sketchup/curved_surface_adapter
  sketchup/layout_writer sketchup/documentation_writer sketchup/grout_writer sketchup/layout_exporter
  tools/face_picker_tool tools/preview_tool tools/documentation_placement_tool tools/arrow_origin_tool
  ui/controller
].each { |file| Sketchup.require(File.join(RevestPlanner::PLUGIN_ROOT, file)) }

module RevestPlanner
  module Main
    module_function

    def open
      UI::Controller.instance.open
    end

    def install_ui
      small_icon = File.join(RevestPlanner::PLUGIN_ROOT, 'assets', 'icons', 'revest_toolbar_24.png')
      large_icon = File.join(RevestPlanner::PLUGIN_ROOT, 'assets', 'icons', 'revest_toolbar_32.png')
      if @toolbar && @command
        @command.small_icon = small_icon
        @command.large_icon = large_icon
        return @toolbar
      end

      @command = ::UI::Command.new('REVEST') { open }
      @command.tooltip = 'Paginação inteligente para SketchUp'
      @command.status_bar_text = 'Abrir o REVEST — Paginação inteligente para SketchUp'
      @command.small_icon = small_icon
      @command.large_icon = large_icon
      ::UI.menu('Extensions').add_item(@command)
      @toolbar = ::UI::Toolbar.new('REVEST')
      @toolbar.add_item(@command)
      @toolbar.restore
      @toolbar
    end

    unless file_loaded?('revest_planner/main')
      install_ui
      file_loaded('revest_planner/main')
    end
  end
end
