# frozen_string_literal: true

module RevestPlanner
  module SketchupAdapter
    # Desenrola uma cadeia de faces suavizadas (parede em arco/cilíndrica) em
    # uma faixa 2D. O motor de paginação continua trabalhando em 2D e esta
    # classe faz a ida e volta entre cada painel plano e a faixa desenrolada.
    class CurvedSurfaceAdapter
      MAX_CONNECTED_FACES = 500
      Panel = Struct.new(:face, :origin, :horizontal, :vertical, :normal, :x0, :x1)

      attr_reader :face, :faces, :frame, :transformation

      def self.build(face, transformation = Geom::Transformation.new)
        connected = smooth_connected_faces(face)
        return FaceAdapter.new(face, transformation) if connected.length < 2
        return FaceAdapter.new(face, transformation) unless genuinely_curved?(connected, transformation)

        new(face, connected, transformation)
      rescue ArgumentError
        FaceAdapter.new(face, transformation)
      end

      # Arestas suavizadas também são usadas para esconder divisões internas
      # de uma parede perfeitamente plana. Só ativamos o desenrolamento quando
      # há mudança real de normal entre as faces.
      def self.genuinely_curved?(faces, transformation)
        reference = faces.first.normal.transform(transformation).normalize
        faces.any? do |item|
          normal = item.normal.transform(transformation).normalize
          reference.dot(normal).abs < 0.9999
        end
      end

      def self.smooth_connected_faces(seed)
        found = [seed]
        queue = [seed]
        until queue.empty?
          current = queue.shift
          current.edges.each do |edge|
            next unless edge.soft? || edge.smooth?

            edge.faces.each do |neighbor|
              next if found.include?(neighbor)

              found << neighbor
              return [seed] if found.length > MAX_CONNECTED_FACES
              queue << neighbor
            end
          end
        end
        found
      end

      def initialize(seed, connected_faces, transformation)
        @face = seed
        @faces = connected_faces
        @transformation = transformation
        @panels = build_panels(connected_faces)
        raise ArgumentError, 'A superfície curva precisa formar uma faixa contínua.' if @panels.length < 2

        @frame = CurvedFrame.new(@panels)
      end

      def curved?
        true
      end

      def clipping_regions
        @clipping_regions ||= @panels.flat_map do |panel|
          polygons_for(panel)
        end
      end

      def area
        faces.inject(0.0) { |sum, item| sum + item.area(transformation) }
      end

      private

      def build_panels(candidates)
        adjacency = candidates.each_with_object({}) { |item, memo| memo[item] = [] }
        candidates.each do |item|
          item.edges.each do |edge|
            next unless edge.soft? || edge.smooth?

            edge.faces.each do |other|
              adjacency[item] << [other, edge] if other != item && adjacency.key?(other)
            end
          end
        end
        raise ArgumentError, 'Superfície curva ramificada.' if adjacency.values.any? { |links| links.length > 2 }

        first = adjacency.find { |_item, links| links.length == 1 }&.first
        raise ArgumentError, 'Selecione uma parede em arco aberta.' unless first

        ordered = []
        previous = nil
        current = first
        while current
          ordered << current
          following = adjacency[current].find { |item, _edge| item != previous }
          previous, current = current, following&.first
        end
        raise ArgumentError, 'A cadeia curva está incompleta.' unless ordered.length == candidates.length

        shared_edges = ordered.each_cons(2).map do |left, right|
          adjacency[left].find { |item, _edge| item == right }[1]
        end
        vertical = common_vertical(shared_edges)
        y_origin = ordered.flat_map(&:vertices).map { |vertex| world(vertex.position).to_a.zip(vertical.to_a).sum { |a, b| a * b } }.min
        cursor = 0.0

        ordered.each_with_index.map do |item, index|
          normal = item.normal.transform(transformation).normalize
          horizontal = vertical.cross(normal).normalize
          centroid = face_center(item)
          if index < ordered.length - 1
            next_center = face_center(ordered[index + 1])
            horizontal.reverse! if centroid.vector_to(next_center).dot(horizontal).negative?
          elsif index.positive?
            previous_center = face_center(ordered[index - 1])
            horizontal.reverse! if previous_center.vector_to(centroid).dot(horizontal).negative?
          end

          projections = item.vertices.map { |vertex| centroid.vector_to(world(vertex.position)).dot(horizontal) }
          low, high = projections.minmax
          width = high - low
          raise ArgumentError, 'Uma faixa da curva possui largura inválida.' if width <= 1.0e-6

          base = centroid.offset(horizontal, low)
          base_projection = base.to_a.zip(vertical.to_a).sum { |a, b| a * b }
          origin = base.offset(vertical, y_origin - base_projection)
          panel = Panel.new(item, origin, horizontal, vertical, normal, cursor, cursor + width)
          cursor += width
          panel
        end
      end

      def common_vertical(edges)
        raise ArgumentError, 'Não há arestas de articulação na curva.' if edges.empty?

        vectors = edges.map do |edge|
          first = world(edge.start.position)
          second = world(edge.end.position)
          first.vector_to(second).normalize
        end
        reference = vectors.first
        vectors.each { |vector| vector.reverse! if vector.dot(reference).negative? }
        axis = vectors.inject(Geom::Vector3d.new(0, 0, 0)) { |sum, vector| sum + vector }.normalize
        unless vectors.all? { |vector| vector.dot(axis).abs > 0.995 }
          raise ArgumentError, 'Esta curva não possui geratrizes paralelas.'
        end
        axis
      end

      def polygons_for(panel)
        mesh = panel.face.mesh(0)
        mesh.polygons.filter_map do |indices|
          points = indices.map { |index| panel_to_2d(panel, world(mesh.point_at(index.abs))) }
          polygon = Core::Polygon2d.new(points)
          polygon if polygon.area > Core::Clipper::EPSILON
        end
      end

      def panel_to_2d(panel, point)
        vector = panel.origin.vector_to(point)
        Core::Point2d.new(panel.x0 + vector.dot(panel.horizontal), vector.dot(panel.vertical))
      end

      def face_center(item)
        points = item.vertices.map { |vertex| world(vertex.position) }
        count = points.length.to_f
        Geom::Point3d.new(points.sum(&:x) / count, points.sum(&:y) / count, points.sum(&:z) / count)
      end

      def world(point)
        point.transform(transformation)
      end

      class CurvedFrame
        attr_reader :origin, :x_axis, :y_axis, :normal

        def initialize(panels)
          @panels = panels
          middle = panels[panels.length / 2]
          @origin = panels.first.origin
          @x_axis = middle.horizontal
          @y_axis = middle.vertical
          @normal = middle.normal
        end

        def to_2d(point)
          panel = @panels.min_by { |item| point.distance_to_plane([item.origin, item.normal]).abs }
          vector = panel.origin.vector_to(point)
          Core::Point2d.new(panel.x0 + vector.dot(panel.horizontal), vector.dot(panel.vertical))
        end

        def to_3d(point, elevation = 0.0)
          panel = panel_for(point.x)
          panel.origin.offset(panel.horizontal, point.x - panel.x0)
                .offset(panel.vertical, point.y).offset(panel.normal, elevation)
        end

        def normal_at(point)
          panel_for(point.x).normal
        end

        private

        def panel_for(x)
          @panels.find { |item| x >= item.x0 - 1.0e-6 && x <= item.x1 + 1.0e-6 } ||
            (x < @panels.first.x0 ? @panels.first : @panels.last)
        end
      end
    end
  end
end
