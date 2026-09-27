# frozen_string_literal: true

module RevestPlanner
  module SketchupAdapter
    # Rejunte: faces finas só nos vãos entre as peças, num subgrupo dentro do grupo da paginação.
    # A face de referência não é tocada e não existe face inteira por baixo das peças: cada região
    # da superfície é desenhada no subgrupo, as peças são desenhadas por cima (o SketchUp as recorta
    # como furos) e depois as faces das peças são apagadas — sobra apenas a malha das juntas.
    class GroutWriter
      GROUP_NAME = 'REVEST - Rejunte'
      DEFAULT_COLOR = '#B9B5AD'
      RECESS = 1.0 / 25.4        # o rejunte fica 1 mm abaixo da face das peças
      CURVED_LIFT = 0.2 / 25.4   # em superfície curva sem espessura, afasta da parede
      TOLERANCE = 1.0e-6

      def self.grout_group(group)
        return nil unless group && group.valid?

        group.entities.grep(Sketchup::Group).find { |child| child.valid? && child.get_attribute('RevestPlanner', 'grout') }
      end

      def self.normalize_color(value)
        hex = value.to_s.strip
        hex = "##{hex}" unless hex.start_with?('#')
        hex.match?(/\A#[0-9a-fA-F]{6}\z/) ? hex.upcase : DEFAULT_COLOR
      end

      def self.material(model, color)
        hex = normalize_color(color)
        name = "REVEST Rejunte #{hex}"
        existing = model.materials[name]
        return existing if existing

        material = model.materials.add(name)
        material.color = Sketchup::Color.new(hex)
        material
      end

      def self.recolor(model, group, color)
        grout = grout_group(group)
        return false unless grout

        grout.material = material(model, color)
        grout.set_attribute('RevestPlanner', 'grout_color', normalize_color(color))
        true
      end

      def self.remove(group)
        grout = grout_group(group)
        grout.erase! if grout
      end

      def initialize(model:, group:, adapter:, result:, thickness:, color:)
        @model = model
        @group = group
        @adapter = adapter
        @result = result
        @thickness = [thickness.to_f, 0.0].max
        @color = self.class.normalize_color(color)
      end

      def write
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        self.class.remove(@group)
        grout = @group.entities.add_group
        grout.name = GROUP_NAME
        grout.set_attribute('RevestPlanner', 'grout', true)
        grout.set_attribute('RevestPlanner', 'grout_color', @color)
        grout.material = self.class.material(@model, @color)
        entities = grout.entities

        piece_faces = outline_mode? ? write_on_outline(entities) : write_on_regions(entities)
        entities.erase_entities(piece_faces.select(&:valid?)) unless piece_faces.empty?
        cleanup_edges(entities)
        if entities.grep(Sketchup::Face).empty?
          grout.erase!
          return nil
        end

        puts format('REVEST rejunte: %.2fs | %d faces', Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
                    entities.grep(Sketchup::Face).length)
        grout
      end

      private

      # Superfície plana: o rejunte nasce do contorno real da face (com os furos), sem a
      # triangulação interna — cujas costuras apareciam como linhas diagonais sobre as peças.
      def outline_mode?
        @adapter.respond_to?(:faces) && @adapter.respond_to?(:transformation) &&
          !(@adapter.respond_to?(:curved?) && @adapter.curved?)
      end

      def write_on_outline(entities)
        @adapter.faces.each do |source|
          outer = clean_points(loop_points(source.outer_loop))
          base = add_face(entities, outer)
          next unless base

          base.reverse! if base.normal.dot(@adapter.frame.normal).negative?
          holes = source.loops.reject(&:outer?).filter_map { |item| add_face(entities, clean_points(loop_points(item))) }
          entities.erase_entities(holes.select(&:valid?)) unless holes.empty?
        end
        # Peça inteira = um único polígono (sem as emendas dos recortes); peça cortada = seus fragmentos.
        @result.pieces.flat_map do |piece|
          shapes = piece.classification == :whole ? [piece.source_polygon] : piece.fragments
          shapes.filter_map do |shape|
            next if shape.area <= Core::LayoutEngine::MIN_FRAGMENT_AREA

            add_face(entities, face_points(shape))
          end
        end
      end

      def loop_points(item)
        frame = @adapter.frame
        item.vertices.map do |vertex|
          frame.to_3d(frame.to_2d(vertex.position.transform(@adapter.transformation)), elevation)
        end
      end

      # Superfície curva: cada painel plano é uma região convexa.
      def write_on_regions(entities)
        regions = @adapter.clipping_regions.map(&:counter_clockwise)
        fragments_by_region = assign_fragments(regions)
        piece_faces = []
        regions.each_with_index do |region, index|
          region_face = add_face(entities, face_points(region))
          next unless region_face

          orient(region_face, region)
          fragments_by_region[index].each do |fragment|
            face = add_face(entities, face_points(fragment))
            piece_faces << face if face
          end
        end
        piece_faces
      end

      # Cada fragmento já é o recorte de uma peça por uma única região convexa da superfície.
      def assign_fragments(regions)
        buckets = Array.new(regions.length) { [] }
        region_bounds = regions.map(&:bounds)
        @result.pieces.each do |piece|
          piece.fragments.each do |fragment|
            next if fragment.area <= Core::LayoutEngine::MIN_FRAGMENT_AREA

            center = centroid(fragment)
            index = regions.each_index.find do |candidate|
              min_x, min_y, max_x, max_y = region_bounds[candidate]
              center.x >= min_x - TOLERANCE && center.x <= max_x + TOLERANCE &&
                center.y >= min_y - TOLERANCE && center.y <= max_y + TOLERANCE &&
                inside_convex?(center, regions[candidate])
            end
            buckets[index] << fragment if index
          end
        end
        buckets
      end

      def centroid(polygon)
        count = polygon.points.length.to_f
        Core::Point2d.new(polygon.points.sum(&:x) / count, polygon.points.sum(&:y) / count)
      end

      def inside_convex?(point, region)
        points = region.points
        points.each_with_index.all? do |start, index|
          (points[(index + 1) % points.length] - start).cross(point - start) >= -TOLERANCE
        end
      end

      def elevation
        @elevation ||= begin
          curved = @adapter.respond_to?(:curved?) && @adapter.curved?
          base = curved ? 0.0 : LayoutWriter::SURFACE_OFFSET
          if @thickness.positive?
            base + @thickness - [RECESS, @thickness * 0.5].min
          else
            # Sem espessura as peças ficam 0,5 mm acima da face; o rejunte fica logo abaixo delas.
            curved ? CURVED_LIFT : base * 0.6
          end
        end
      end

      def face_points(polygon)
        clean_points(polygon.points.map { |point| @adapter.frame.to_3d(point, elevation) })
      end

      def clean_points(points)
        unique = []
        points.each do |position|
          unique << position unless unique.any? { |existing| existing.distance(position) <= TOLERANCE }
        end
        return unique if unique.length < 3

        unique.reject.with_index do |current, index|
          previous = unique[index - 1]
          following = unique[(index + 1) % unique.length]
          (current - previous).cross(following - current).length <= TOLERANCE
        end
      end

      def add_face(entities, points)
        return nil if points.length < 3

        entities.add_face(points)
      rescue ArgumentError, RuntimeError
        nil
      end

      def orient(face, region)
        frame = @adapter.frame
        expected = frame.respond_to?(:normal_at) ? frame.normal_at(centroid(region)) : frame.normal
        face.reverse! if face.normal.dot(expected).negative?
      end

      # Sobram arestas soltas onde uma peça encostava na borda da região, e costuras entre as
      # regiões (triângulos da face). As soltas somem; as costuras coplanares são unidas.
      def cleanup_edges(entities)
        loose = entities.grep(Sketchup::Edge).select { |edge| edge.faces.empty? }
        entities.erase_entities(loose) unless loose.empty?
        entities.grep(Sketchup::Edge).each do |edge|
          next unless edge.valid? && edge.faces.length == 2

          first, second = edge.faces
          next unless first.normal.parallel?(second.normal)

          begin
            edge.erase!
          rescue ArgumentError, RuntimeError
            nil
          end
        end
        # As bordas das juntas já aparecem pelas arestas das próprias peças. Ocultar as do rejunte
        # evita qualquer linha residual vazando através das peças.
        entities.grep(Sketchup::Edge).each { |edge| edge.hidden = true if edge.valid? }
      end
    end
  end
end
