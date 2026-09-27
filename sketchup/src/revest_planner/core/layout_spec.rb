# frozen_string_literal: true

module RevestPlanner
  module Core
    class LayoutSpec
      PATTERNS = [
        :aligned, :vertical, :diagonal, :brick,
        :checkerboard, :alternating, :chevron, :herringbone, :quartzito
      ].freeze

      attr_reader :pattern, :rotation, :offset_u, :offset_v, :stagger

      def initialize(pattern: :aligned, rotation: 0.0, offset_u: 0.0, offset_v: 0.0, stagger: 0.5)
        @pattern = pattern.to_sym
        @rotation = Float(rotation)
        @offset_u = Float(offset_u)
        @offset_v = Float(offset_v)
        @stagger = Float(stagger)
        raise ArgumentError, 'Padrão não suportado.' unless PATTERNS.include?(@pattern)
        raise ArgumentError, 'A amarração deve estar entre 0 e 1.' unless @stagger.between?(0.0, 1.0)
      end
    end
  end
end
