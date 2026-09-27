# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module RevestPlanner
  PLUGIN_ID = 'revest_planner'
  PLUGIN_NAME = 'REVEST'

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(
      PLUGIN_NAME,
      File.join(PLUGIN_ID, 'main')
    )
    extension.description = 'Planejamento e quantitativo de paginações de revestimentos.'
    extension.version = '0.2.0'
    extension.creator = 'REVEST'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
