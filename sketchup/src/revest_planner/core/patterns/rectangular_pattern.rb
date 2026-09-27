# frozen_string_literal: true

module RevestPlanner
  module Core
    module Patterns
      class RectangularPattern
        Cell = Struct.new(:id, :polygon, :nominal_area)

        def initialize(tile_spec, layout_spec)
          @tile = tile_spec
          @layout = layout_spec
        end

        def cells_covering(bounds)
          local_bounds = inverse_rotated_bounds(bounds)
          min_x, min_y, max_x, max_y = local_bounds
          row_min = ((min_y - @layout.offset_v) / @tile.pitch_y).floor - 1
          row_max = ((max_y - @layout.offset_v) / @tile.pitch_y).ceil + 1
          cells = []

          (row_min..row_max).each do |row|
            row_shift = shift_for(row)
            base_x = @layout.offset_u + row_shift
            column_min = ((min_x - base_x) / @tile.pitch_x).floor - 1
            column_max = ((max_x - base_x) / @tile.pitch_x).ceil + 1

            (column_min..column_max).each do |column|
              x = base_x + (column * @tile.pitch_x)
              y = @layout.offset_v + (row * @tile.pitch_y)
              polygon = rectangle(x, y).rotate(effective_rotation)
              cells << Cell.new("r#{row}c#{column}", polygon, @tile.area)
            end
          end
          cells
        end

        private

        def shift_for(row)
          case @layout.pattern
          when :brick
            row.odd? ? @tile.pitch_x * @layout.stagger : 0.0
          else
            0.0
          end
        end

        def effective_rotation
          extra = case @layout.pattern
                  when :diagonal then Math::PI / 4.0
                  when :vertical then Math::PI / 2.0
                  else 0.0
                  end
          @layout.rotation + extra
        end

        def rectangle(x, y)
          Polygon2d.new([
            Point2d.new(x, y),
            Point2d.new(x + @tile.width, y),
            Point2d.new(x + @tile.width, y + @tile.height),
            Point2d.new(x, y + @tile.height)
          ])
        end

        def inverse_rotated_bounds(bounds)
          min_x, min_y, max_x, max_y = bounds
          corners = [
            Point2d.new(min_x, min_y), Point2d.new(max_x, min_y),
            Point2d.new(max_x, max_y), Point2d.new(min_x, max_y)
          ].map { |point| point.rotate(-effective_rotation) }
          xs = corners.map(&:x)
          ys = corners.map(&:y)
          [xs.min, ys.min, xs.max, ys.max]
        end
      end
    end
  end
end
