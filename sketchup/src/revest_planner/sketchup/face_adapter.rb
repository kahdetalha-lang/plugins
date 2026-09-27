# frozen_string_literal: true

module RevestPlanner
  module SketchupAdapter
    class FaceAdapter
      attr_reader :face, :faces, :frame, :transformation

      def initialize(face, transformation = Geom::Transformation.new)
        raise ArgumentError, 'Selecione uma face válida.' unless face.is_a?(Sketchup::Face) && face.valid?

        @face = face
        @transformation = transformation
        @frame = PlaneFrame.from_face(face, transformation)
        # A face escolhida delimita exatamente a área de paginação. Faces
        # coplanares adjacentes só entram quando houver seleção explícita.
        @faces = [face]
      end

      def self.coplanar_connected_faces(seed)
        plane = [seed.vertices.first.position, seed.normal]
        found = [seed]
        queue = [seed]
        until queue.empty?
          current = queue.shift
          current.edges.each do |edge|
            edge.faces.each do |neighbor|
              next if neighbor == current || found.include?(neighbor)
              next unless neighbor.normal.parallel?(seed.normal)
              next unless neighbor.vertices.all? { |vertex| vertex.position.distance_to_plane(plane).abs <= 1.0e-5 }

              found << neighbor
              queue << neighbor
            end
          end
        end
        found
      end

      def clipping_regions
        @clipping_regions ||= faces.flat_map { |item| regions_for(item) }
      end

      def area
        faces.inject(0.0) { |sum, item| sum + item.area(transformation) }
      end

      private

      # Uma parede pode estar repartida em várias faces pelo encontro de
      # vergas, recortes e linhas auxiliares. Para a paginação, todas as faces
      # coplanares ligadas pertencem à mesma superfície; quinas e outros planos
      # interrompem naturalmente a busca.
      def regions_for(item)
        if item.loops.length == 1
          boundary = Core::Polygon2d.new(
            item.outer_loop.vertices.map do |vertex|
              frame.to_2d(vertex.position.transform(transformation))
            end
          )
          return [boundary] if boundary.convex?
        end

        mesh = item.mesh(0)
        mesh.polygons.each_with_object([]) do |indices, regions|
          points = indices.map do |index|
            frame.to_2d(mesh.point_at(index.abs).transform(transformation))
          end
          polygon = Core::Polygon2d.new(points)
          regions << polygon if polygon.area > Core::Clipper::EPSILON
        end
      end
    end
  end
end
