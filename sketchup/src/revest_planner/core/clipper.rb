# frozen_string_literal: true

module RevestPlanner
  module Core
    module Clipper
      EPSILON = 1.0e-8
      module_function

      # Sutherland-Hodgman: o polígono de recorte deve ser convexo.
      def intersection(subject, convex_clip)
        output = subject.points.dup
        clip_points = convex_clip.counter_clockwise.points

        clip_points.each_with_index do |edge_start, index|
          edge_end = clip_points[(index + 1) % clip_points.length]
          input = output
          output = []
          break if input.empty?

          previous = input.last
          input.each do |current|
            current_inside = inside?(current, edge_start, edge_end)
            previous_inside = inside?(previous, edge_start, edge_end)

            if current_inside
              output << line_intersection(previous, current, edge_start, edge_end) unless previous_inside
              output << current
            elsif previous_inside
              output << line_intersection(previous, current, edge_start, edge_end)
            end
            previous = current
          end
        end

        cleaned = Polygon2d.clean(output)
        return nil if cleaned.length < 3

        polygon = Polygon2d.new(cleaned)
        polygon.area > EPSILON ? polygon : nil
      end

      def inside?(point, edge_start, edge_end)
        edge = edge_end - edge_start
        relative = point - edge_start
        edge.cross(relative) >= -EPSILON
      end

      def line_intersection(segment_start, segment_end, line_start, line_end)
        segment = segment_end - segment_start
        line = line_end - line_start
        denominator = segment.cross(line)
        return segment_end if denominator.abs <= EPSILON

        delta = line_start - segment_start
        factor = delta.cross(line) / denominator
        segment_start + (segment * factor)
      end
    end
  end
end
