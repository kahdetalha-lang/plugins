# frozen_string_literal: true
require 'sketchup.rb'
require 'extensions.rb'

module KahDetalha
  module CentralKPilot
    VERSION = '1.0.3'.freeze
    PLUGIN_ROOT = File.dirname(__FILE__).freeze
    MAIN_PATH = File.join(PLUGIN_ROOT, 'central_k_pilot', 'main').freeze

    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('Central K-Plugins', MAIN_PATH)
      extension.description = 'Login, catálogo e ativação automática dos plugins Kah Detalha (K.Cenas, K.Light).'
      extension.version = VERSION
      extension.creator = 'Kah Detalha'
      extension.copyright = "2026, Kah Detalha"
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
