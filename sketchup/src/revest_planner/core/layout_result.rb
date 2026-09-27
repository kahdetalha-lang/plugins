# frozen_string_literal: true

module RevestPlanner
  module Core
    class LayoutResult
      attr_reader :pieces

      def initialize(pieces)
        @pieces = pieces.freeze
      end

      def whole_count
        pieces.count { |piece| piece.classification == :whole }
      end

      def cut_count
        pieces.count { |piece| piece.classification == :cut }
      end

      def covered_area
        pieces.inject(0.0) { |sum, piece| sum + piece.net_area }
      end

      def rectangular_cuts
        pieces.select(&:rectangular_cut?).group_by do |piece|
          piece.cut_dimensions.map { |value| value.round(6) }
        end.transform_values(&:length)
      end

      def irregular_cut_count
        pieces.count { |piece| piece.classification == :cut && !piece.rectangular_cut? }
      end

      def to_h
        {
          whole_count: whole_count,
          cut_count: cut_count,
          covered_area: covered_area,
          rectangular_cuts: rectangular_cuts,
          irregular_cut_count: irregular_cut_count
        }
      end
    end
  end
end
