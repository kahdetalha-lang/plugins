# frozen_string_literal: true

module RevestPlanner
  module Core
    class Polygon2d
      EPSILON = 1.0e-8

      attr_reader :points

      def initialize(points)
        @points = self.class.clean(points)
        raise ArgumentError, 'Um polígono precisa de pelo menos três pontos.' if @points.length < 3
      end

      def self.clean(points)
        cleaned = []
        points.each do |point|
          candidate = point.is_a?(Point2d) ? point : Point2d.new(point[0].to_f, point[1].to_f)
          cleaned << candidate if cleaned.empty? || cleaned.last.distance(candidate) > EPSILON
        end
        cleaned.pop if cleaned.length > 1 && cleaned.first.distance(cleaned.last) <= EPSILON
        cleaned
      end

      def signed_area
        sum = 0.0
        points.each_with_index do |point, index|
          following = points[(index + 1) % points.length]
          sum += (point.x * following.y) - (following.x * point.y)
        end
        sum / 2.0
      end

      def area
        signed_area.abs
      end

      def counter_clockwise
        signed_area.negative? ? Polygon2d.new(points.reverse) : self
      end

      def bounds
        xs = points.map(&:x)
        ys = points.map(&:y)
        [xs.min, ys.min, xs.max, ys.max]
      end

      def rectangular?(tolerance = 1.0e-6)
        return false unless points.length == 4

        min_x, min_y, max_x, max_y = bounds
        bounding_area = (max_x - min_x) * (max_y - min_y)
        (area - bounding_area).abs <= tolerance
      end

      def convex?
        signs = []
        points.each_with_index do |point, index|
          first = points[(index + 1) % points.length] - point
          second = points[(index + 2) % points.length] - points[(index + 1) % points.length]
          cross = first.cross(second)
          signs << (cross <=> 0) if cross.abs > EPSILON
        end
        signs.empty? || signs.uniq.length == 1
      end

      def rotate(angle, origin = Point2d.new(0.0, 0.0))
        Polygon2d.new(points.map { |point| point.rotate(angle, origin) })
      end

      def translate(vector)
        Polygon2d.new(points.map { |point| point + vector })
      end
    end
  end
end
