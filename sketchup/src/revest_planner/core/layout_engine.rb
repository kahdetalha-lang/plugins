# frozen_string_literal: true

module RevestPlanner
  module Core
    class LayoutEngine
      DEFAULT_TOLERANCE = 1.0e-6
      # Abaixo desta área (polegadas quadradas), o fragmento é apenas ruído de
      # ponto flutuante criado quando uma peça tangencia vértices da malha.
      # Enviá-lo ao SketchUp pode invalidar faces vizinhas perfeitamente boas.
      MIN_FRAGMENT_AREA = 1.0e-6

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
        pattern = pattern_generator
        pieces = pattern.cells_covering(bounds).each_with_object([]) do |cell, output|
          cell_bounds = cell.polygon.bounds
          next unless bounds_overlap?(cell_bounds, bounds)

          fragments = region_bounds.each_with_object([]) do |(region, bounds_for_region), clipped|
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

      private

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
