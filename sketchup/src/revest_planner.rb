# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module RevestPlanner
  PLUGIN_ID = 'revest_planner' unless defined?(PLUGIN_ID)
  PLUGIN_NAME = 'REVEST' unless defined?(PLUGIN_NAME)
  # Pasta do plugin. Os arquivos internos são carregados com Sketchup.require a partir daqui:
  # require_relative e __dir__ não funcionam depois que a Trimble criptografa os arquivos (.rbe).
  PLUGIN_ROOT = File.join(File.dirname(__FILE__), PLUGIN_ID) unless defined?(PLUGIN_ROOT)

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(
      PLUGIN_NAME,
      File.join(PLUGIN_ID, 'main')
    )
    extension.description = 'Planejamento e quantitativo de paginações de revestimentos.'
    extension.version = '1.0.0'
    extension.creator = 'Kah Detalha'
    extension.copyright = '© 2026 Kah Detalha'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
