# frozen_string_literal: true

module RevestPlanner
  module Core
    class LayoutEngine
      DEFAULT_TOLERANCE = 1.0e-6
      # Abaixo desta área (polegadas quadradas), o fragmento é apenas ruído de
      # ponto flutuante criado quando uma peça tangencia vértices da malha.
      # Enviá-lo ao SketchUp pode invalidar faces vizinhas perfeitamente boas.
      MIN_FRAGMENT_AREA = 1.0e-6
      # Acima disso o cálculo (e o SketchUp) ficaria lento a ponto de parecer travado — por exemplo,
      # ao digitar "1" a caminho de "120" numa face grande. Interrompe antes de gerar as células.
      MAX_PIECES = 80_000

      # clipping_regions são polígonos convexos, normalmente triângulos de uma
      # malha da face. Fragmentos da mesma célula permanecem agrupados.
      def initialize(tile_spec:, layout_spec:, tolerance: DEFAULT_TOLERANCE)
        @tile_spec = tile_spec
        @layout_spec = layout_spec
        @tolerance = tolerance
      end

      def call(clipping_regions)
        validate_regions!(clipping_regions)
        region_bounds = clipping_regions.map { |region| [region, region.bounds] }
        bounds = combined_bounds(region_bounds.map(&:last))
        check_piece_limit!(bounds)
        index = RegionIndex.new(region_bounds, bounds)
        pattern = pattern_generator
        pieces = pattern.cells_covering(bounds).each_with_object([]) do |cell, output|
          cell_bounds = cell.polygon.bounds
          next unless bounds_overlap?(cell_bounds, bounds)

          fragments = index.candidates(cell_bounds).each_with_object([]) do |(region, bounds_for_region), clipped|
            next unless bounds_overlap?(cell_bounds, bounds_for_region)

            fragment = Clipper.intersection(cell.polygon, region)
            clipped << fragment if fragment && fragment.area > MIN_FRAGMENT_AREA
          end
          next if fragments.empty?

          output << Piece.new(
            cell_id: cell.id,
            fragments: fragments,
            nominal_area: cell.nominal_area || @tile_spec.area,
            source_polygon: cell.polygon,
            tolerance: @tolerance
          )
        end
        LayoutResult.new(pieces)
      end

      # Faces com recortes chegam como muitos triângulos. Uma grade simples evita testar cada peça
      # contra todos eles (o custo passava a ser peças × triângulos a cada tecla digitada).
      class RegionIndex
        def initialize(region_bounds, bounds)
          @all = region_bounds
          @grid = nil
          return if region_bounds.length <= 8

          width = [bounds[2] - bounds[0], 1.0e-6].max
          height = [bounds[3] - bounds[1], 1.0e-6].max
          @divisions = [[Math.sqrt(region_bounds.length).ceil, 1].max, 64].min
          @origin_x = bounds[0]
          @origin_y = bounds[1]
          @cell_w = width / @divisions
          @cell_h = height / @divisions
          @grid = Hash.new { |hash, key| hash[key] = [] }
          region_bounds.each_with_index do |entry, position|
            each_key(entry[1]) { |key| @grid[key] << position }
          end
        end

        def candidates(box)
          return @all unless @grid

          positions = []
          each_key(box) { |key| positions.concat(@grid.fetch(key, [])) }
          positions.uniq.sort.map { |position| @all[position] }
        end

        private

        def each_key(box)
          x0 = clamp(((box[0] - @origin_x) / @cell_w).floor)
          x1 = clamp(((box[2] - @origin_x) / @cell_w).floor)
          y0 = clamp(((box[1] - @origin_y) / @cell_h).floor)
          y1 = clamp(((box[3] - @origin_y) / @cell_h).floor)
          (x0..x1).each { |x| (y0..y1).each { |y| yield [x, y] } }
        end

        def clamp(value)
          [[value, 0].max, @divisions - 1].min
        end
      end

      private

      def check_piece_limit!(bounds)
        area = (bounds[2] - bounds[0]) * (bounds[3] - bounds[1])
        per_piece = case @layout_spec.pattern
                    when :quartzito
                      (@tile_spec.width * @tile_spec.height) / Patterns::QUARTZITO_SHAPES.length.to_f
                    when :chevron
                      # Cada peça avança a largura e ocupa 1/3 da altura informada.
                      @tile_spec.width * @tile_spec.height / 3.0
                    when :checkerboard, :herringbone
                      @tile_spec.width * @tile_spec.height
                    else
                      @tile_spec.pitch_x * @tile_spec.pitch_y
                    end
        estimate = per_piece.positive? ? area / per_piece : Float::INFINITY
        return if estimate <= MAX_PIECES

        raise ArgumentError, "Peças pequenas demais para esta área (cerca de #{estimate.round.to_s.reverse.scan(/\d{1,3}/).join('.').reverse} peças). " \
                             'Aumente o tamanho da peça ou divida a superfície em partes menores.'
      end

      def pattern_generator
        if @layout_spec.pattern == :quartzito
          Patterns::QuartzitoPattern.new(@tile_spec, @layout_spec)
        elsif [:checkerboard, :chevron, :herringbone].include?(@layout_spec.pattern)
          Patterns::CompositePattern.new(@tile_spec, @layout_spec)
        else
          Patterns::RectangularPattern.new(@tile_spec, @layout_spec)
        end
      end

      def validate_regions!(regions)
        raise ArgumentError, 'É necessária ao menos uma região de recorte.' if regions.empty?
        unless regions.all? { |region| region.is_a?(Polygon2d) }
          raise ArgumentError, 'Todas as regiões devem ser Polygon2d.'
        end
      end

      def combined_bounds(bounds)
        [
          bounds.map { |item| item[0] }.min,
          bounds.map { |item| item[1] }.min,
          bounds.map { |item| item[2] }.max,
          bounds.map { |item| item[3] }.max
        ]
      end

      def bounds_overlap?(first, second)
        first[2] >= second[0] && second[2] >= first[0] &&
          first[3] >= second[1] && second[3] >= first[1]
      end
    end
  end
end
