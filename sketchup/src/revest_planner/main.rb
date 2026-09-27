# frozen_string_literal: true

require_relative 'core'
require_relative 'sketchup/plane_frame'
require_relative 'sketchup/face_adapter'
require_relative 'sketchup/curved_surface_adapter'
require_relative 'sketchup/layout_writer'
require_relative 'sketchup/documentation_writer'
require_relative 'sketchup/grout_writer'
require_relative 'ui/controller'

module RevestPlanner
  module Main
    module_function

    def open
      UI::Controller.instance.open
    end

    def install_ui
      small_icon = File.join(__dir__, 'assets', 'icons', 'revest_toolbar_24.png')
      large_icon = File.join(__dir__, 'assets', 'icons', 'revest_toolbar_32.png')
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

    unless file_loaded?(__FILE__)
      install_ui
      file_loaded(__FILE__)
    end
  end
end
