# frozen_string_literal: true

# Sketchup.require (sem extensão) carrega tanto .rb quanto os .rbe criptografados.
%w[
  core/point2d
  core/polygon2d
  core/clipper
  core/tile_spec
  core/layout_spec
  core/patterns/rectangular_pattern
  core/patterns/composite_pattern
  core/patterns/quartzito_data
  core/patterns/quartzito_pattern
  core/piece
  core/layout_result
  core/layout_engine
  core/grout_geometry
].each { |file| Sketchup.require(File.join(RevestPlanner::PLUGIN_ROOT, file)) }
