# frozen_string_literal: true

module RevestPlanner
  module Core
    module Patterns
      class CompositePattern
        Cell = Struct.new(:id, :polygon, :nominal_area)

        def initialize(tile_spec, layout_spec)
          @tile = tile_spec
          @layout = layout_spec
        end

        def cells_covering(bounds)
          local_bounds = rotated_bounds(bounds, -@layout.rotation)
          cells = case @layout.pattern
                  when :checkerboard then checkerboard(local_bounds)
                  when :herringbone then herringbone(local_bounds, false)
                  when :chevron then chevron(local_bounds)
                  when :french then french(local_bounds)
                  else []
                  end
          cells.map { |cell| Cell.new(cell.id, cell.polygon.rotate(@layout.rotation), cell.nominal_area) }
        end

        private

        def checkerboard(bounds)
          length = [@tile.width, @tile.height].max
          width = [@tile.width, @tile.height].min
          count = [(length / [width, 1.0e-6].max).round, 1].max
          block = length + @tile.joint
          strip_pitch = block / count.to_f
          strip_width = strip_pitch - @tile.joint
          raise ArgumentError, 'Junta grande demais para o padrão Dama.' unless strip_width.positive?
          ranges(bounds, block, block).each_with_object([]) do |(row, column), cells|
            x = @layout.offset_u + column * block
            y = @layout.offset_v + row * block
            vertical = (row + column).odd?
            count.times do |index|
              polygon = if vertical
                          rectangle(x + index * strip_pitch, y, strip_width, length)
                        else
                          rectangle(x, y + index * strip_pitch, length, strip_width)
                        end
              cells << Cell.new("d#{row}_#{column}_#{index}", polygon, length * strip_width)
            end
          end
        end

        def herringbone(bounds, chevron)
          # Na interface a peça é informada como largura x altura (7 x 25 cm).
          # Para a espinha, a maior dimensão é o comprimento da régua.
          length = [@tile.width, @tile.height].max
          width = [@tile.width, @tile.height].min
          root_two = Math.sqrt(2.0)
          step_x = (width + @tile.joint) * root_two
          step_y = (length + @tile.joint) * root_two
          down = Point2d.new(1.0 / root_two, -1.0 / root_two)
          up = Point2d.new(1.0 / root_two, 1.0 / root_two)
          across_down = chevron ? Point2d.new(step_x, 0.0) : up * width
          across_up = chevron ? Point2d.new(step_x, 0.0) : down * -width
          ranges(bounds, step_x, step_y).each_with_object([]) do |(row, column), cells|
            origin = Point2d.new(@layout.offset_u + column * step_x, @layout.offset_v + row * step_y)
            first = polygon_from_vectors(origin, down * length, across_down)
            second = polygon_from_vectors(origin, up * length, across_up)
            prefix = chevron ? 'c' : 'h'
            cells << Cell.new("#{prefix}#{row}_#{column}a", first, first.area)
            cells << Cell.new("#{prefix}#{row}_#{column}b", second, second.area)
          end
        end

        # Chevron vetorizado do modelo Revestimento Escama de Peixe. Cada
        # peça é um paralelogramo; colunas alternadas formam sucessivos Vs.
        # A altura informada é a caixa total da peça (22,5 cm no preset),
        # dividida em 2/3 de avanço e 1/3 de faixa.
        def chevron(bounds)
          run = @tile.width
          total_height = @tile.height
          band = total_height / 3.0
          rise = total_height - band
          min_x, min_y, max_x, max_y = bounds
          column_min = ((min_x - @layout.offset_u) / run).floor - 2
          column_max = ((max_x - @layout.offset_u) / run).ceil + 2
          row_min = ((min_y - @layout.offset_v - total_height) / band).floor - 2
          row_max = ((max_y - @layout.offset_v) / band).ceil + 2

          (row_min..row_max).each_with_object([]) do |row, cells|
            y = @layout.offset_v + row * band
            (column_min..column_max).each do |column|
              x = @layout.offset_u + column * run
              points = if column.even?
                         [Point2d.new(x, y), Point2d.new(x, y + band),
                          Point2d.new(x + run, y + rise + band), Point2d.new(x + run, y + rise)]
                       else
                         [Point2d.new(x, y + rise), Point2d.new(x, y + rise + band),
                          Point2d.new(x + run, y + band), Point2d.new(x + run, y)]
                       end
              polygon = radial_inset(Polygon2d.new(points), @tile.joint * 0.5)
              # A área nominal deve considerar o recuo da junta. Caso contrário,
              # toda peça íntegra é classificada incorretamente como recortada.
              cells << Cell.new("c#{row}_#{column}", polygon, polygon.area)
            end
          end
        end

        def radial_inset(polygon, distance)
          return polygon if distance <= 0.0

          center = Point2d.new(polygon.points.sum(&:x) / polygon.points.length.to_f,
                               polygon.points.sum(&:y) / polygon.points.length.to_f)
          Polygon2d.new(polygon.points.map do |point|
            vector = point - center
            length = vector.distance(Point2d.new(0.0, 0.0))
            center + vector * ((length - [distance, length * 0.2].min) / length)
          end)
        end

        def french(bounds)
          size = [@tile.width, @tile.height].max
          unit = size * 2.0 + @tile.joint * 3.0
          ranges(bounds, unit, unit).each_with_object([]) do |(row, column), cells|
            x = @layout.offset_u + column * unit
            y = @layout.offset_v + row * unit
            half = size / 2.0
            shapes = [
              [x, y, size, size], [x + size + @tile.joint, y, half, half],
              [x + size + half + @tile.joint * 2, y, half, size],
              [x + size + @tile.joint, y + half + @tile.joint, half, size + half],
              [x, y + size + @tile.joint, size, size],
              [x + size + half + @tile.joint * 2, y + size + @tile.joint, half, size]
            ]
            shapes.each_with_index do |shape, index|
              polygon = rectangle(*shape)
              cells << Cell.new("f#{row}_#{column}_#{index}", polygon, polygon.area)
            end
          end
        end

        def polygon_from_vectors(origin, along, across)
          Polygon2d.new([origin, origin + along, origin + along + across, origin + across])
        end

        def rectangle(x, y, width, height)
          Polygon2d.new([Point2d.new(x, y), Point2d.new(x + width, y),
                         Point2d.new(x + width, y + height), Point2d.new(x, y + height)])
        end

        def ranges(bounds, step_x, step_y)
          min_x, min_y, max_x, max_y = bounds
          columns = (((min_x - @layout.offset_u) / step_x).floor - 2)..(((max_x - @layout.offset_u) / step_x).ceil + 2)
          rows = (((min_y - @layout.offset_v) / step_y).floor - 2)..(((max_y - @layout.offset_v) / step_y).ceil + 2)
          rows.flat_map { |row| columns.map { |column| [row, column] } }
        end

        def rotated_bounds(bounds, angle)
          min_x, min_y, max_x, max_y = bounds
          points = [Point2d.new(min_x, min_y), Point2d.new(max_x, min_y),
                    Point2d.new(max_x, max_y), Point2d.new(min_x, max_y)].map { |point| point.rotate(angle) }
          xs = points.map(&:x)
          ys = points.map(&:y)
          [xs.min, ys.min, xs.max, ys.max]
        end
      end
    end
  end
end
