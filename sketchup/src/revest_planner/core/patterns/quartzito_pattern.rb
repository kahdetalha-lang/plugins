# frozen_string_literal: true

module RevestPlanner
  module Core
    module Patterns
      class QuartzitoPattern
        Cell = Struct.new(:id, :polygon, :nominal_area)

        def initialize(tile_spec, layout_spec)
          @tile = tile_spec
          @layout = layout_spec
        end

        def cells_covering(bounds)
          local = rotated_bounds(bounds, -@layout.rotation)
          width = @tile.width
          height = @tile.height
          min_x, min_y, max_x, max_y = local
          anchor_u, anchor_v = pattern_anchor
          origin_x = @layout.offset_u - anchor_u * width
          origin_y = @layout.offset_v - anchor_v * height
          columns = ((min_x - origin_x) / width).floor..(((max_x - origin_x) / width).ceil - 1)
          rows = ((min_y - origin_y) / height).floor..(((max_y - origin_y) / height).ceil - 1)

          rows.each_with_object([]) do |row, cells|
            columns.each do |column|
              softened_shapes.each_with_index do |shape, index|
                points = shape.map do |point|
                  Point2d.new(@layout.offset_u + (column + point.x - anchor_u) * width,
                              @layout.offset_v + (row + point.y - anchor_v) * height)
                end
                polygon = inset(Polygon2d.new(points), @tile.joint * 0.5).rotate(@layout.rotation)
                cells << Cell.new("q#{row}_#{column}_#{index}", polygon, polygon.area)
              end
            end
          end
        end

        private

        # O ponto inicial deve coincidir com uma pedra, não apenas com o canto
        # da caixa envolvente do painel original.
        def pattern_anchor
          @pattern_anchor ||= QUARTZITO_SHAPES.flatten(1).min_by do |u, v|
            (u * u) + (v * v)
          end
        end

        def softened_shapes
          @softened_shapes ||= QUARTZITO_SHAPES.map do |shape|
            soften_corners(shape.map { |u, v| Point2d.new(u, v) })
          end
        end

        # Uma passagem de Chaikin substitui cada quina por dois pontos. O
        # contorno continua leve para a prévia, mas perde o aspecto facetado
        # produzido pela simplificação do desenho original.
        def soften_corners(points)
          points.each_with_index.flat_map do |point, index|
            following = points[(index + 1) % points.length]
            vector = following - point
            [point + vector * 0.22, point + vector * 0.78]
          end
        end

        def inset(polygon, distance)
          return polygon if distance <= 0.0

          center = Point2d.new(polygon.points.sum(&:x) / polygon.points.length.to_f,
                               polygon.points.sum(&:y) / polygon.points.length.to_f)
          Polygon2d.new(polygon.points.map do |point|
            vector = point - center
            length = vector.distance(Point2d.new(0.0, 0.0))
            length <= distance ? point : center + vector * ((length - distance) / length)
          end)
        end

        def rotated_bounds(bounds, angle)
          min_x, min_y, max_x, max_y = bounds
          corners = [Point2d.new(min_x,min_y),Point2d.new(max_x,min_y),
                     Point2d.new(max_x,max_y),Point2d.new(min_x,max_y)].map { |point| point.rotate(angle) }
          xs = corners.map(&:x); ys = corners.map(&:y)
          [xs.min, ys.min, xs.max, ys.max]
        end
      end
    end
  end
end
