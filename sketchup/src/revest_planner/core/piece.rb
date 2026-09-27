# frozen_string_literal: true

module RevestPlanner
  module Core
    class Piece
      attr_reader :cell_id, :fragments, :nominal_area, :classification, :source_polygon

      def initialize(cell_id:, fragments:, nominal_area:, source_polygon:, tolerance: 1.0e-6)
        @cell_id = cell_id
        @fragments = fragments.freeze
        @nominal_area = nominal_area
        @source_polygon = source_polygon
        # O recorte sobre uma face triangulada acumula pequenos erros de ponto
        # flutuante. A tolerância relativa evita marcar peças completas como
        # cortadas, sem esconder perdas reais nas bordas.
        area_tolerance = [tolerance, nominal_area.abs * 1.0e-5].max
        @classification = (nominal_area - net_area).abs <= area_tolerance ? :whole : :cut
      end

      def net_area
        fragments.inject(0.0) { |sum, polygon| sum + polygon.area }
      end

      def rectangular_cut?
        classification == :cut && fragments.length == 1 && fragments.first.rectangular?
      end

      def cut_dimensions
        return nil unless rectangular_cut?

        min_x, min_y, max_x, max_y = fragments.first.bounds
        [max_x - min_x, max_y - min_y].sort.reverse
      end
    end
  end
end
