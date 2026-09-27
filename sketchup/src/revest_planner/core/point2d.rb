# frozen_string_literal: true

module RevestPlanner
  module Core
    Point2d = Struct.new(:x, :y) do
      def +(other)
        Point2d.new(x + other.x, y + other.y)
      end

      def -(other)
        Point2d.new(x - other.x, y - other.y)
      end

      def *(scalar)
        Point2d.new(x * scalar, y * scalar)
      end

      def cross(other)
        (x * other.y) - (y * other.x)
      end

      def distance(other)
        Math.sqrt(((x - other.x)**2) + ((y - other.y)**2))
      end

      def rotate(angle, origin = Point2d.new(0.0, 0.0))
        cosine = Math.cos(angle)
        sine = Math.sin(angle)
        local_x = x - origin.x
        local_y = y - origin.y
        Point2d.new(
          origin.x + (local_x * cosine) - (local_y * sine),
          origin.y + (local_x * sine) + (local_y * cosine)
        )
      end
    end
  end
end
