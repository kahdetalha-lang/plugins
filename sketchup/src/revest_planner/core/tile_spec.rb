# frozen_string_literal: true

module RevestPlanner
  module Core
    class TileSpec
      attr_reader :width, :height, :joint

      def initialize(width:, height:, joint: 0.0)
        @width = Float(width)
        @height = Float(height)
        @joint = Float(joint)
        raise ArgumentError, 'Largura e altura devem ser positivas.' unless @width.positive? && @height.positive?
        raise ArgumentError, 'A junta não pode ser negativa.' if @joint.negative?
      end

      def area
        width * height
      end

      def pitch_x
        width + joint
      end

      def pitch_y
        height + joint
      end
    end
  end
end
