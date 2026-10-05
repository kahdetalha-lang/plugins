# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module RevestPlanner
  PLUGIN_ID = 'revest_planner' unless const_defined?(:PLUGIN_ID, false)
  PLUGIN_NAME = 'REVEST' unless const_defined?(:PLUGIN_NAME, false)
  # Pasta do plugin. Os arquivos internos são carregados com Sketchup.require a partir daqui:
  # require_relative e __dir__ não funcionam depois que a Trimble criptografa os arquivos (.rbe).
  # const_defined?(..., false) olha só dentro do RevestPlanner: defined?(PLUGIN_ROOT) também enxergava
  # um PLUGIN_ROOT global de outro plugin e aí o nosso nunca era criado (NameError ao carregar).
  PLUGIN_ROOT = File.join(File.dirname(__FILE__), PLUGIN_ID) unless const_defined?(:PLUGIN_ROOT, false)

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(
      PLUGIN_NAME,
      File.join(PLUGIN_ID, 'main')
    )
    extension.description = 'Planejamento e quantitativo de paginações de revestimentos.'
    extension.version = '1.0.1'
    extension.creator = 'Kah Detalha'
    extension.copyright = '© 2026 Kah Detalha'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
