# frozen_string_literal: true

require 'json'

module RevestPlanner
  module SketchupAdapter
    class LayoutWriter
      SURFACE_OFFSET = 0.5 / 25.4
      MIN_TRIANGLE_ALTITUDE = 0.002 # polegadas (aprox. 0,05 mm)

      def initialize(model:, adapter:, result:, materials: [], thickness: 0.0, metadata: nil, replace_group: nil, texture_variation: 1)
        @model = model
        @adapter = adapter
        @result = result
        @materials = materials
        @thickness = [thickness.to_f, 0.0].max
        @metadata = metadata
        @replace_group = replace_group
        @texture_variation = [[texture_variation.to_i, 1].max, 4].min
        @force_legacy = false
        @using_builder = false
        @skipped_precision_slivers = 0
      end

      def write
        started_at = monotonic_time
        @model.start_operation('Gerar paginação', true)
        group = @model.active_entities.add_group
        group.name = 'REVEST - Paginação'
        entities = group.entities
        fast_pieces, slow_pieces = @result.pieces.partition { |piece| fast_solid_geometry?(entities, piece) }
        needs_internal_cleanup = false

        slow_pieces.each do |piece|
          material = material_for(piece)
          piece.fragments.each do |fragment|
            next if fragment.area <= Core::LayoutEngine::MIN_FRAGMENT_AREA

            points = clean_face_points(fragment.points.map { |point| @adapter.frame.to_3d(point, surface_offset) })
            next if points.length < 3

            created_faces = add_fragment_faces(entities, points)
            needs_internal_cleanup ||= piece.fragments.length > 1 || created_faces.length > 1
            created_faces.each { |face| identify_face(face, piece, fragment, material) }
          end
        end
        geometry_at = monotonic_time
        # A inclusão de uma aresta posterior pode repartir uma face já criada.
        # O SketchUp nem sempre copia material e atributos para todas as partes.
        # Reconciliar ao final evita ilhas cinzas sem revestimento.
        reconcile_top_faces(entities)
        reconcile_at = monotonic_time
        remove_internal_fragment_edges(entities) if needs_internal_cleanup
        first_cleanup_at = monotonic_time
        if @thickness.positive?
          extrude_piece_faces(entities)
          extruded_at = monotonic_time
          # PushPull may recreate triangulation/cut seams on the new top face.
          # Run the same piece-aware cleanup once more after extrusion.
          remove_internal_fragment_edges(entities) if needs_internal_cleanup
        else
          extruded_at = first_cleanup_at
        end
        fast_started_at = monotonic_time
        unless fast_pieces.empty?
          @using_builder = true
          build_fast_solids(entities, fast_pieces)
          @using_builder = false
        end
        extrusion_at = monotonic_time
        group.set_attribute('RevestPlanner', 'whole_count', @result.whole_count)
        group.set_attribute('RevestPlanner', 'cut_count', @result.cut_count)
        group.set_attribute('RevestPlanner', 'thickness_mm', @thickness * 25.4)
        group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(@metadata)) if @metadata
        @replace_group.erase! if @replace_group && @replace_group.valid? && @replace_group != group
        @model.commit_operation
        puts format(
          'REVEST desempenho: geometria %.2fs | conferência %.2fs | extrusão/limpeza %.2fs | total %.2fs | %d peças',
          geometry_at - started_at, reconcile_at - geometry_at,
          extrusion_at - reconcile_at, monotonic_time - started_at, @result.pieces.length
        )
        puts format(
          'REVEST detalhes: limpeza inicial %.2fs | extrusão %.2fs | limpeza final %.2fs | lote 3D %.2fs | %d peças em lote',
          first_cleanup_at - reconcile_at, extruded_at - first_cleanup_at,
          fast_started_at - extruded_at, extrusion_at - fast_started_at, fast_pieces.length
        )
        puts "REVEST: #{@skipped_precision_slivers} recortes inferiores à precisão do SketchUp foram ignorados." if @skipped_precision_slivers.positive?
        group
      rescue StandardError => error
        puts "REVEST diagnóstico: #{error.class}: #{error.message}"
        puts Array(error.backtrace).first(8).join("\n")
        @model.abort_operation
        if @using_builder && !@force_legacy
          puts "REVEST: geração em lote indisponível neste modelo (#{error.message}); repetindo pelo método seguro."
          @using_builder = false
          @force_legacy = true
          return write
        end
        raise
      end

      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def fast_solid_geometry?(entities, piece)
        state = @metadata && @metadata['state']
        @thickness.positive? && entities.respond_to?(:build) &&
          !@force_legacy &&
          !(@adapter.respond_to?(:curved?) && @adapter.curved?) &&
          state && !state['dry_joint'] && state['joint'].to_f.positive? &&
          piece.classification == :whole && piece.fragments.length == 1
      end

      def build_fast_solids(entities, pieces)
        entities.build do |builder|
          pieces.each do |piece|
            fragment = piece.fragments.first
            base = clean_face_points(fragment.points.map { |point| @adapter.frame.to_3d(point, surface_offset) })
            raise ArgumentError, 'Uma peça inteira possui contorno inválido.' if base.length < 3

            normal = @adapter.frame.normal
            first = base[0].vector_to(base[1])
            second = base[0].vector_to(base[2])
            base.reverse! if first.cross(second).dot(normal).negative?
            top = base.map { |point| point.offset(normal, @thickness) }
            top_face = builder.add_face(top)
            raise ArgumentError, 'Não foi possível criar a face superior de uma peça.' unless top_face

            material = material_for(piece)
            identify_face(top_face, piece, fragment, material, surface_offset + @thickness)
            bottom_face = builder.add_face(base.reverse)
            bottom_face.material = material if material && bottom_face
            base.length.times do |index|
              following = (index + 1) % base.length
              side_face = builder.add_face(base[index], base[following], top[following], top[index])
              side_face.material = material if material && side_face
            end
          end
        end
      end

      def add_fragment_faces(entities, points)
        face = begin
          entities.add_face(points)
        rescue ArgumentError, RuntimeError => error
          raise unless error.message.match?(/planar/i)

          nil
        end
        return [face] if face

        # Fragmentos do clipper são convexos. Um vértice quase colinear pode
        # criar um triângulo microscópico que o SketchUp não consegue fechar.
        faces = points.drop(1).each_cons(2).filter_map do |second, third|
          triangle = [points.first, second, third]
          if precision_sliver?(triangle)
            @skipped_precision_slivers += 1
            next
          end

          begin
            entities.add_face(triangle)
          rescue ArgumentError, RuntimeError => error
            raise unless error.message.match?(/planar/i) && entities.respond_to?(:build)

            built_face = nil
            begin
              entities.build { |builder| built_face = builder.add_face(triangle) }
            rescue ArgumentError, RuntimeError => builder_error
              raise unless builder_error.message.match?(/planar/i) && precision_sliver?(triangle, MIN_TRIANGLE_ALTITUDE * 2.0)

              @skipped_precision_slivers += 1
              next
            end
            built_face
          end
        end

        faces
      end

      def precision_sliver?(triangle, minimum_altitude = MIN_TRIANGLE_ALTITUDE)
        first, second, third = triangle
        sides = [first.distance(second), second.distance(third), third.distance(first)]
        longest = sides.max
        return true if longest < 1.0e-6

        twice_area = first.vector_to(second).cross(first.vector_to(third)).length
        twice_area / longest < minimum_altitude
      end

      def identify_face(face, piece, fragment, material, elevation = surface_offset)
        expected_normal = if @adapter.frame.respond_to?(:normal_at)
                            @adapter.frame.normal_at(fragment.points.first)
                          else
                            @adapter.frame.normal
                          end
        face.reverse! unless face.normal.samedirection?(expected_normal)
        apply_material(face, piece, material, elevation) if material
        face.set_attribute('RevestPlanner', 'piece_id', piece.cell_id)
        face.set_attribute('RevestPlanner', 'classification', piece.classification.to_s)
      end

      def reconcile_top_faces(entities)
        faces = entities.grep(Sketchup::Face)
        piece_by_id = @result.pieces.each_with_object({}) { |piece, memo| memo[piece.cell_id] = piece }
        unresolved = []

        faces.each do |face|
          piece_id = face.get_attribute('RevestPlanner', 'piece_id')
          piece = piece_id && piece_by_id[piece_id]
          if piece
            # Faces intactas já receberam material durante a criação. Só
            # corrigimos uma subdivisão que perdeu material no SketchUp.
            if !@materials.empty? && (!face.material || !face.material.texture)
              apply_material(face, piece, material_for(piece))
            end
          else
            unresolved << face
          end
        end
        return if unresolved.empty?

        index, cell_size = fragment_spatial_index
        unresolved.each do |face|
          local = face_center_2d(face)
          key = spatial_key(local, cell_size)
          candidates = index[key] || []
          piece = candidates.find do |candidate|
            candidate.fragments.any? { |fragment| point_in_polygon?(local, fragment) }
          end
          next unless piece

          face.set_attribute('RevestPlanner', 'piece_id', piece.cell_id)
          face.set_attribute('RevestPlanner', 'classification', piece.classification.to_s)
          material = material_for(piece)
          apply_material(face, piece, material) if material
        end
      end

      def fragment_spatial_index
        dimensions = @result.pieces.flat_map do |piece|
          piece.fragments.map do |fragment|
            min_x, min_y, max_x, max_y = fragment.bounds
            [max_x - min_x, max_y - min_y]
          end
        end.flatten.select(&:positive?)
        cell_size = dimensions.empty? ? 1.0 : [dimensions.sum / dimensions.length.to_f, 1.0e-3].max
        index = Hash.new { |hash, key| hash[key] = [] }
        @result.pieces.each do |piece|
          piece.fragments.each do |fragment|
            min_x, min_y, max_x, max_y = fragment.bounds
            x0, y0 = spatial_key(Core::Point2d.new(min_x, min_y), cell_size)
            x1, y1 = spatial_key(Core::Point2d.new(max_x, max_y), cell_size)
            (x0..x1).each do |x|
              (y0..y1).each { |y| index[[x, y]] << piece unless index[[x, y]].include?(piece) }
            end
          end
        end
        [index, cell_size]
      end

      def spatial_key(point, cell_size)
        [(point.x / cell_size).floor, (point.y / cell_size).floor]
      end

      def face_center_2d(face)
        points = face.outer_loop.vertices.map { |vertex| @adapter.frame.to_2d(vertex.position) }
        count = points.length.to_f
        Core::Point2d.new(points.sum(&:x) / count, points.sum(&:y) / count)
      end

      def point_in_polygon?(point, polygon)
        inside = false
        vertices = polygon.points
        previous = vertices.last
        vertices.each do |current|
          return true if point_on_2d_segment?(point, previous, current)

          crosses = (current.y > point.y) != (previous.y > point.y)
          if crosses
            intersection_x = ((previous.x - current.x) * (point.y - current.y) /
                              (previous.y - current.y)) + current.x
            inside = !inside if point.x < intersection_x
          end
          previous = current
        end
        inside
      end

      def point_on_2d_segment?(point, first, second)
        edge = second - first
        relative = point - first
        return false if relative.cross(edge).abs > 1.0e-6

        dot = (relative.x * edge.x) + (relative.y * edge.y)
        dot >= -1.0e-6 && dot <= (edge.x * edge.x) + (edge.y * edge.y) + 1.0e-6
      end

      # Recortes tangentes a quinas e aberturas podem devolver o mesmo vértice
      # mais de uma vez. O SketchUp não aceita pontos duplicados em add_face.
      def clean_face_points(points)
        tolerance = 1.0e-6
        unique = []
        points.each do |point|
          unique << point unless unique.any? { |existing| existing.distance(point) <= tolerance }
        end
        return unique if unique.length < 3

        changed = true
        while changed && unique.length > 3
          changed = false
          unique.length.times do |index|
            previous = unique[(index - 1) % unique.length]
            current = unique[index]
            following = unique[(index + 1) % unique.length]
            first = current - previous
            second = following - current
            next unless first.cross(second).length <= tolerance

            unique.delete_at(index)
            changed = true
            break
          end
        end
        unique
      end

      def remove_internal_fragment_edges(entities)
        entities.grep(Sketchup::Edge).each do |edge|
          next unless edge.valid? && edge.faces.length == 2

          faces = edge.faces
          ids = faces.map { |face| face.get_attribute('RevestPlanner', 'piece_id') }
          next unless ids[0] && ids[0] == ids[1]
          next unless faces[0].normal.parallel?(faces[1].normal)

          begin
            edge.erase!
          rescue ArgumentError, RuntimeError => error
            # Faces quase coplanares podem ser válidas separadamente, mas o
            # SketchUp rejeita a fusão em um único polígono. A costura pode
            # permanecer; não deve impedir a geração da paginação inteira.
            raise unless error.message.match?(/planar/i)
          end
        end
      end

      # The clipping engine can divide one piece into several coplanar fragments.
      # Internal fragment edges are removed first, so each finished piece is
      # push-pulled only once and no duplicate internal side walls are created.
      def extrude_piece_faces(entities)
        top_faces = entities.grep(Sketchup::Face).select do |face|
          face.valid? && face.get_attribute('RevestPlanner', 'piece_id')
        end
        top_faces.each do |face|
          next unless face.valid?

          # pushpull já preserva o material da peça. Evitar comparar a lista
          # completa de faces antes/depois de cada peça elimina o custo O(n²).
          face.pushpull(@thickness, false)
        end
      end

      def material_for(piece)
        return nil if @materials.empty?

        if @texture_variation == 4 && @materials.length >= 2
          index = alternating_material_index(piece.cell_id)
          return @materials[index] unless index.nil?
        end

        if @texture_variation <= 3 && @materials.length >= 2
          index = scattered_material_index(piece.cell_id)
          return @materials[index] unless index.nil?
        end

        @materials[piece_hash(piece) % @materials.length]
      end

      # Distribuições 1–3 evitam sequências longas da mesma imagem na mesma
      # fileira, mas conservam pequenas quebras para não parecer um xadrez.
      def scattered_material_index(cell_id)
        match = cell_id.to_s.match(/r(-?\d+)c(-?\d+)/)
        return nil unless match

        row = match[1].to_i
        column = match[2].to_i
        block_size = { 1 => 3, 2 => 2, 3 => 4 }.fetch(@texture_variation, 3)
        row_seed = stable_grid_hash(row, @texture_variation) % @materials.length
        (column + column.div(block_size) + row_seed) % @materials.length
      end

      def stable_grid_hash(value, variation)
        number = (value * 1_103_515_245) ^ (variation * 12_345)
        number ^= (number >> 16)
        number.abs
      end

      def alternating_material_index(cell_id)
        id = cell_id.to_s
        if (match = id.match(/r(-?\d+)c(-?\d+)/))
          return (match[1].to_i + match[2].to_i).even? ? 0 : 1
        end
        if (match = id.match(/d(-?\d+)_(-?\d+)_(-?\d+)/))
          return (match[1].to_i + match[2].to_i + match[3].to_i).even? ? 0 : 1
        end

        nil
      end

      def piece_hash(piece)
        hash = 2_166_136_261
        piece.cell_id.each_byte do |byte|
          hash ^= byte
          hash = (hash * 16_777_619) & 0xffffffff
        end
        hash ^= (@texture_variation * 2_654_435_761) & 0xffffffff
        hash ^= (hash >> 13)
        hash = (hash * 1_274_126_177) & 0xffffffff
        hash ^ (hash >> 16)
      end

      def apply_material(face, piece, material, elevation = surface_offset)
        face.material = material
        face.back_material = material
        corners = if @adapter.frame.respond_to?(:normal_at)
                    face.vertices.first(3).map { |vertex| @adapter.frame.to_2d(vertex.position) }
                  else
                    piece.source_polygon.points
                  end
        model_points = corners.map { |point| @adapter.frame.to_3d(point, elevation) }
        # Fotos de revestimentos frequentemente incluem veios e bordas com
        # orientação definida. Girar ou espelhar o UV cria encontros falsos.
        # A variação ocorre somente pela escolha do material/imagem.
        quarter_turn = texture_quarter_turn(piece, material)
        uv = orientation_aware_uv(material, model_points).map { |coordinates| rotate_uv(coordinates, quarter_turn) }
        mapping = []
        3.times do |index|
          mapping << model_points[index]
          mapping << Geom::Point3d.new(uv[index][0], uv[index][1], 0)
        end
        face.position_material(material, mapping, true)
        face.set_attribute('RevestPlanner', 'texture_quarter_turn', quarter_turn)
      rescue StandardError => error
        face.material = material
        face.back_material = material
        puts "REVEST: posicionamento de textura simplificado (#{error.message})"
      end

      def texture_quarter_turn(piece, material)
        return 0 if @texture_variation == 4

        preserve_texture_proportion((piece_hash(piece) >> 8) % 4, material)
      end

      # Em uma superfície curva, afastar cada painel na direção de sua própria
      # normal abriria pequenas frestas nas articulações. A espessura já projeta
      # o revestimento para fora, portanto a base nasce diretamente na parede.
      def surface_offset
        @adapter.respond_to?(:curved?) && @adapter.curved? ? 0.0 : SURFACE_OFFSET
      end

      # Um giro de 90° troca os eixos U/V. Em imagens retangulares isso força
      # o SketchUp a adaptar largura à altura e produz textura esticada. Para
      # essas imagens mantemos apenas 0°/180°, que preservam a proporção.
      def preserve_texture_proportion(quarter_turn, material)
        texture = material && material.texture
        image_width = texture && texture.respond_to?(:image_width) ? texture.image_width.to_f : 0.0
        image_height = texture && texture.respond_to?(:image_height) ? texture.image_height.to_f : 0.0
        return quarter_turn unless image_width.positive? && image_height.positive?
        return quarter_turn if (image_width / image_height - 1.0).abs < 0.02

        quarter_turn.even? ? quarter_turn : (quarter_turn + 1) % 4
      end

      def rotate_uv(coordinates, quarter_turn)
        u, v = coordinates
        case quarter_turn % 4
        when 1 then [1.0 - v, u]
        when 2 then [1.0 - u, 1.0 - v]
        when 3 then [v, 1.0 - u]
        else [u, v]
        end
      end

      # Algumas paginações constroem o polígono começando pelo lado comprido
      # da peça. Imagens de réguas normalmente começam pelo lado estreito.
      # Alinhamos automaticamente esses eixos sem ampliar, recortar ou esticar.
      def orientation_aware_uv(material, model_points)
        texture = material.texture
        image_width = texture.respond_to?(:image_width) ? texture.image_width.to_f : 0.0
        image_height = texture.respond_to?(:image_height) ? texture.image_height.to_f : 0.0
        first_edge = model_points[0].distance(model_points[1])
        second_edge = model_points[1].distance(model_points[2])
        return [[0, 0], [1, 0], [1, 1]] unless image_width.positive? && image_height.positive? && second_edge.positive?

        piece_ratio = first_edge / second_edge
        image_ratio = image_width / image_height
        normal_error = (Math.log(piece_ratio / image_ratio)).abs
        rotated_error = (Math.log(piece_ratio * image_ratio)).abs
        rotated_error < normal_error ? [[0, 0], [0, 1], [1, 1]] : [[0, 0], [1, 0], [1, 1]]
      end

    end
  end
end
