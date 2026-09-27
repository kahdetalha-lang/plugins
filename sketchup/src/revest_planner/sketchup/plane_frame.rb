# frozen_string_literal: true

module RevestPlanner
  module SketchupAdapter
    class PlaneFrame
      attr_reader :origin, :x_axis, :y_axis, :normal

      def self.from_face(face, transformation = Geom::Transformation.new)
        edge = face.edges.max_by(&:length)
        edge_start = edge.start.position.transform(transformation)
        edge_end = edge.end.position.transform(transformation)
        x_axis = edge_start.vector_to(edge_end).normalize
        normal = face.normal.transform(transformation).normalize
        y_axis = (normal * x_axis).normalize
        origin = face.vertices.first.position.transform(transformation)
        new(origin, x_axis, y_axis, normal)
      end

      def initialize(origin, x_axis, y_axis, normal)
        @origin = origin
        @x_axis = x_axis
        @y_axis = y_axis
        @normal = normal
      end

      def to_2d(point)
        vector = origin.vector_to(point)
        Core::Point2d.new(vector.dot(x_axis), vector.dot(y_axis))
      end

      def to_3d(point, elevation = 0.0)
        origin.offset(x_axis, point.x).offset(y_axis, point.y).offset(normal, elevation)
      end
    end
  end
end
