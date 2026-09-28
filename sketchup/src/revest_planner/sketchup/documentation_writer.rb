# frozen_string_literal: true

require 'json'

module RevestPlanner
  module SketchupAdapter
    # Desenha somente entidades de anotação em subgrupos do revestimento.
    # Nenhuma face ou aresta da paginação é modificada.
    class DocumentationWriter
      KEYS = %w[start direction tag].freeze

      def initialize(model:, group:, metadata:)
        @model = model
        @group = group
        @metadata = metadata
        face = model.find_entity_by_persistent_id(metadata['face_pid'].to_i)
        raise ArgumentError, 'A face original desta paginação não existe mais.' unless face.is_a?(Sketchup::Face) && face.valid?

        transformation = Geom::Transformation.new(Array(metadata['transformation']))
        @adapter = FaceAdapter.new(face, transformation)
        @frame = @adapter.frame
        bounds = @adapter.clipping_regions.map(&:bounds)
        @min_x = bounds.map { |box| box[0] }.min
        @min_y = bounds.map { |box| box[1] }.min
        @max_x = bounds.map { |box| box[2] }.max
        @max_y = bounds.map { |box| box[3] }.max
        state = metadata['state'] || {}
        @elevation = state['thickness'].to_f / 25.4 + 0.06
        @angle_degrees = state['rotation'].to_f + (state['pattern'] == 'diagonal' ? 45.0 : state['pattern'] == 'vertical' ? 90.0 : 0.0)
        @angle = @angle_degrees.degrees
      end

      def self.documentation_child(group, key)
        group.entities.grep(Sketchup::Group).find do |child|
          child.valid? && child.get_attribute('RevestPlanner', 'documentation_key') == key
        end
      end

      # As setas se resumem a: quantidade (1–3), rotação (passos de 90°), tamanho e ponto de união.
      # (Com setas perpendiculares, "inverter" e "espelhar" são apenas rotações de 90°/180°.)
      def self.arrow_rotation(options)
        return options['direction_rotation'].to_i % 360 unless options['direction_rotation'].nil?

        # Modelos antigos: converte inverter/espelhar em rotação equivalente.
        ((options['direction_inverted'] ? 180 : 0) + (options['direction_mirrored'] ? 90 : 0)) % 360
      end

      def self.arrow_count(options)
        [[options.fetch('arrow_count', 2).to_i, 1].max, 3].min
      end

      def self.arrow_scale(options)
        scale = options['direction_scale'].to_f
        scale.positive? ? scale.clamp(0.25, 4.0) : 1.0
      end

      def apply(keys = KEYS)
        @metadata['documentation'] ||= {}
        options = @metadata['documentation']
        keys.each do |key|
          existing = self.class.documentation_child(@group, key)
          # Posição real no modelo (inclui o que foi movido à mão com a ferramenta Mover).
          @displayed_tag_corner = displayed_tag_corner(existing) if key == 'tag'
          capture_moved_arrows(existing, options) if key == 'direction'
          existing.erase! if existing && existing.valid?
          next unless options[key]

          child = @group.entities.add_group
          child.name = { 'start' => 'REVEST - Início da paginação', 'direction' => 'REVEST - Sentido da paginação', 'tag' => 'REVEST - Tag do revestimento' }.fetch(key)
          child.set_attribute('RevestPlanner', 'documentation_key', key)
          case key
          when 'start' then draw_start(child.entities)
          when 'direction'
            draw_direction(child.entities)
            child.set_attribute('RevestPlanner', 'arrow_junction', @arrow_junction) if @arrow_junction
          when 'tag' then draw_tag(child.entities)
          end
        end
        assign_documentation_layer
      end

      DOCUMENTATION_LAYER = '00- REVEST ELEMENTOS'
      OLD_DOCUMENTATION_LAYER = '00- REVEST ELEMENTO' # nome da versão de teste: é renomeada

      # Tag, setas e hachura (de todas as paginações) ficam na etiqueta padrão "00- REVEST ELEMENTO",
      # para ligar/desligar por cena — ex.: visível na planta, oculta na vista ISO. A etiqueta só é
      # criada quando existe algum desses elementos.
      def assign_documentation_layer
        children = @group.entities.grep(Sketchup::Group).select do |child|
          child.valid? && child.get_attribute('RevestPlanner', 'documentation_key')
        end
        return if children.empty?

        layer = @model.layers[DOCUMENTATION_LAYER]
        unless layer
          old = @model.layers[OLD_DOCUMENTATION_LAYER]
          old.name = DOCUMENTATION_LAYER if old
          layer = old || @model.layers.add(DOCUMENTATION_LAYER)
        end
        children.each { |child| child.layer = layer unless child.layer == layer }
      rescue StandardError => error
        puts "REVEST não aplicou a etiqueta da documentação: #{error.message}"
      end

      # Antes de recriar a paginação: grava nas opções a posição real da tag e das setas,
      # incluindo movimentos feitos à mão, para elas voltarem no mesmo lugar.
      def capture_manual_moves
        options = (@metadata['documentation'] ||= {})
        corner = displayed_tag_corner(self.class.documentation_child(@group, 'tag'))
        options['tag_corner'] = corner if corner
        capture_moved_arrows(self.class.documentation_child(@group, 'direction'), options)
      end

      private

      def point(x, y)
        @frame.to_3d(Core::Point2d.new(x, y), @elevation)
      end

      def line(entities, x1, y1, x2, y2)
        entities.add_line(point(x1, y1), point(x2, y2))
      end

      BORDO = [118, 28, 44].freeze

      def technical_red
        @technical_red ||= begin
          material = @model.materials['REVEST - Indicações técnicas'] || @model.materials.add('REVEST - Indicações técnicas')
          material.color = Sketchup::Color.new(*BORDO)
          material
        end
      end

      def hatch_material
        @hatch_material ||= begin
          material = @model.materials['REVEST - Peça inicial'] || @model.materials.add('REVEST - Peça inicial')
          material.color = Sketchup::Color.new(*BORDO)
          material.alpha = 1.0
          material
        end
      end

      def tag_background
        @tag_background ||= begin
          material = @model.materials['REVEST - Fundo da tag'] || @model.materials.add('REVEST - Fundo da tag')
          material.color = Sketchup::Color.new(244, 243, 240)
          material.alpha = 0.62
          material
        end
      end

      def tag_ink
        @tag_ink ||= begin
          material = @model.materials['REVEST - Texto da tag'] || @model.materials.add('REVEST - Texto da tag')
          material.color = Sketchup::Color.new(35, 39, 41)
          material
        end
      end

      def filled_polygon(entities, coordinates, material = technical_red, elevation = @elevation, hide_edges: false)
        face = entities.add_face(coordinates.map { |x, y| @frame.to_3d(Core::Point2d.new(x, y), elevation) })
        return unless face

        face.material = material
        face.back_material = material
        # Traços finos: arestas ocultas para a cor vir só do material, independente do estilo de arestas.
        face.edges.each { |edge| edge.hidden = true } if hide_edges
        face
      end

      def span
        [@max_x - @min_x, @max_y - @min_y].min
      end

      def draw_start(entities)
        faces = start_piece_faces
        return if faces.empty?

        bounds = bounds_for(faces)
        width = bounds[2] - bounds[0]
        height = bounds[3] - bounds[1]
        pitch = [[width, height].min / 12.0, 0.12].max
        band = pitch * 0.08
        axis = 1.0 / Math.sqrt(2.0)
        faces.each do |face|
          mesh = face.mesh(0)
          mesh.polygons.each do |indices|
            vertices = indices.map { |index| @frame.to_2d(mesh.point_at(index.abs)) }
            next if vertices.length < 3

            region = Core::Polygon2d.new(vertices)
            values = vertices.map { |vertex| (vertex.x - vertex.y) * axis }
            # Extensão da listra medida na própria peça (e não a partir da origem do plano),
            # para a hachura cobrir a peça inteira onde quer que ela esteja.
            along = vertices.map { |vertex| (vertex.x + vertex.y) * axis }
            t_min = along.min - pitch
            t_max = along.max + pitch
            from = (values.min / pitch).floor - 1
            to = (values.max / pitch).ceil + 1
            (from..to).each do |stripe|
              begin
                center = stripe * pitch
                corners = [-band / 2.0, band / 2.0].flat_map do |offset|
                  value = center + offset
                  [Core::Point2d.new(axis * value + axis * t_min, -axis * value + axis * t_min),
                   Core::Point2d.new(axis * value + axis * t_max, -axis * value + axis * t_max)]
                end
                strip = Core::Polygon2d.new([corners[0], corners[1], corners[3], corners[2]])
                clipped = Core::Clipper.intersection(strip, region)
                next unless clipped && clipped.area > 1.0e-6

                filled_polygon(entities, clipped.points.map { |vertex| [vertex.x, vertex.y] }, hatch_material,
                               hide_edges: true)
              rescue ArgumentError, RuntimeError => error
                raise unless error.message.match?(/planar|small|edge/i)
              end
            end
          end
        end
      end

      def start_coordinates
        explicit = @metadata['anchor_point']
        if explicit.is_a?(Array) && explicit.length == 3
          local = @frame.to_2d(Geom::Point3d.new(explicit))
          return [local.x, local.y]
        end

        state = @metadata['state'] || {}
        local = Core::Point2d.new(state['offset_u'].to_f / 25.4, state['offset_v'].to_f / 25.4).rotate(@angle)
        [local.x, local.y]
      end

      def piece_faces
        target_elevation = (@metadata.dig('state', 'thickness').to_f / 25.4) + LayoutWriter::SURFACE_OFFSET
        @piece_faces ||= @group.entities.grep(Sketchup::Face).select do |face|
          next false unless face.valid? && face.get_attribute('RevestPlanner', 'piece_id') && face.normal.parallel?(@frame.normal)

          elevation = @frame.origin.vector_to(face.vertices.first.position).dot(@frame.normal)
          (elevation - target_elevation).abs < 0.08
        end
      end

      # Peça inicial: a escolhida à mão ("Escolher peça inicial") ou, senão, a peça que começa no
      # ponto de início da paginação. Esse ponto é um canto compartilhado por até 4 peças; a certa é
      # a do lado em que se clicou (`anchor_direction`, gravado no clique) — ou, sem clique, a do
      # quadrante positivo da grade, onde a paginação começa.
      def start_piece_faces
        options = @metadata['documentation'] || {}
        selected_id = options['start_piece_manual'] ? options['start_piece_id'] : nil
        if selected_id.nil? || piece_faces.none? { |face| face.get_attribute('RevestPlanner', 'piece_id') == selected_id }
          selected_id = automatic_start_piece_id
        end
        piece_faces.select { |face| face.get_attribute('RevestPlanner', 'piece_id') == selected_id }
      end

      def automatic_start_piece_id
        @automatic_start_piece_id ||= begin
          anchor_x, anchor_y = start_coordinates
          u_axis = [Math.cos(@angle), Math.sin(@angle)]
          v_axis = [-Math.sin(@angle), Math.cos(@angle)]
          direction = @metadata['anchor_direction']
          clicked_side = direction.is_a?(Array) && direction.length == 2
          report = @metadata['report'] || {}
          piece_size = [report['width'].to_f, report['height'].to_f].select(&:positive?).min
          step = piece_size ? piece_size / 2.54 * 0.2 : 0.5
          if clicked_side
            # Direção canto -> peça clicada, gravada no clique: o ponto de prova anda nela, sem
            # arredondar para uma diagonal (uma direção quase reta escolhia o lado errado).
            length = Math.hypot(direction[0].to_f, direction[1].to_f)
            length = 1.0 if length < 1.0e-9
            probe_x = anchor_x + direction[0].to_f / length * step
            probe_y = anchor_y + direction[1].to_f / length * step
          else
            probe_x = anchor_x + (u_axis[0] + v_axis[0]) * step
            probe_y = anchor_y + (u_axis[1] + v_axis[1]) * step
          end
          probe = Geom::Point3d.new(probe_x, probe_y, 0.0)
          anchor = Geom::Point3d.new(anchor_x, anchor_y, 0.0)
          polygon_of = lambda do |face|
            face.outer_loop.vertices.map do |vertex|
              local = @frame.to_2d(vertex.position)
              Geom::Point3d.new(local.x, local.y, 0.0)
            end
          end
          containing = piece_faces.find { |face| Geom.point_in_polygon_2D(probe, polygon_of.call(face), true) }
          if containing.nil? && clicked_side
            # Paginações antigas (direção canto -> clique) que caíram na junta: diagonal do mesmo lado.
            du = direction[0].to_f * u_axis[0] + direction[1].to_f * u_axis[1]
            dv = direction[0].to_f * v_axis[0] + direction[1].to_f * v_axis[1]
            su = du.negative? ? -1.0 : 1.0
            sv = dv.negative? ? -1.0 : 1.0
            probe = Geom::Point3d.new(anchor_x + (su * u_axis[0] + sv * v_axis[0]) * step,
                                      anchor_y + (su * u_axis[1] + sv * v_axis[1]) * step, 0.0)
            probe_x = probe.x
            probe_y = probe.y
            containing = piece_faces.find { |face| Geom.point_in_polygon_2D(probe, polygon_of.call(face), true) }
          end

          # Peças que encostam no ponto de início (o canto é compartilhado por até 4 peças; a junta
          # afasta cada peça alguns milímetros do ponto exato).
          touch = (@metadata.dig('state', 'joint').to_f / 2.54) + 0.4
          touching = piece_faces.select do |face|
            polygon = polygon_of.call(face)
            Geom.point_in_polygon_2D(anchor, polygon, true) ||
              polygon.each_with_index.any? do |a, index|
                b = polygon[index - 1]
                anchor.distance_to_line([a, b]) <= touch &&
                  (anchor.distance(a) + anchor.distance(b) - a.distance(b)) <= touch * 2
              end
          end

          chosen = if clicked_side && containing
                     containing # a peça do lado em que se clicou
                   elsif touching.any?
                     # Sem o lado do clique: a maior peça (uma peça inteira, não um recorte);
                     # em empate, a do sentido padrão da grade.
                     largest = touching.map(&:area).max
                     whole = touching.select { |face| face.area >= largest * 0.98 }
                     whole.include?(containing) ? containing : whole.first
                   else
                     containing
                   end
          chosen ||= piece_faces.min_by do |face|
            local = face_center(face)
            (local.x - probe_x)**2 + (local.y - probe_y)**2
          end
          chosen && chosen.get_attribute('RevestPlanner', 'piece_id')
        end
      end

      def face_center(face)
        vertices = face.outer_loop.vertices.map { |vertex| @frame.to_2d(vertex.position) }
        Core::Point2d.new(vertices.sum(&:x) / vertices.length, vertices.sum(&:y) / vertices.length)
      end

      def bounds_for(faces)
        vertices = faces.flat_map { |face| face.outer_loop.vertices.map { |vertex| @frame.to_2d(vertex.position) } }
        [vertices.map(&:x).min, vertices.map(&:y).min, vertices.map(&:x).max, vertices.map(&:y).max]
      end

      def draw_direction(entities)
        setup = arrow_setup
        return unless setup

        x, y = setup[:point]
        @arrow_junction = [x, y]
        setup[:directions].each do |radians|
          # Cada seta no próprio subgrupo: as hastes que partem do mesmo ponto não se fundem.
          arrow = entities.add_group
          arrow.name = 'Seta'
          filled_polygon(arrow.entities, arrow_outline(x, y, radians, setup[:length]), technical_red, hide_edges: true)
        end
      end

      public

      attr_reader :frame, :elevation

      # Direções (radianos), comprimento e ponto de união das setas, no sistema 2D da paginação.
      # `rotation`, `count` e `scale` permitem à ferramenta mostrar a prévia antes de gravar.
      def arrow_setup(rotation: nil, count: nil, scale: nil)
        options = @metadata['documentation'] || {}
        faces = start_piece_faces
        return nil if faces.empty?

        bounds = bounds_for(faces)
        size = [bounds[2] - bounds[0], bounds[3] - bounds[1]].min
        base_length = options['direction_length'].to_f.positive? ? options['direction_length'].to_f : [size * 0.4, 0.25].max
        length = base_length * (scale || self.class.arrow_scale(options))
        rotation ||= self.class.arrow_rotation(options)
        count ||= self.class.arrow_count(options)
        angle = arrow_base_angle + rotation
        directions = [angle.degrees]
        directions << (angle - 90.0).degrees if count >= 2
        directions << (angle + 90.0).degrees if count == 3
        chosen_point = options['direction_point']
        point = if chosen_point.is_a?(Array) && chosen_point.length >= 2
                  [chosen_point[0].to_f, chosen_point[1].to_f]
                else
                  automatic_direction_point(bounds, directions, length)
                end
        { directions: directions, length: length, point: point }
      end

      # Contorno 2D (sistema da paginação) de cada peça — usado pelo encaixe automático das setas.
      def piece_outlines_2d
        @piece_outlines_2d ||= piece_faces.map do |face|
          face.outer_loop.vertices.map do |vertex|
            local = @frame.to_2d(vertex.position)
            [local.x, local.y]
          end
        end
      end

      # Das duas direções da grade (base e base + 90°), qual o usuário vê como "horizontal":
      # em parede, a mais deitada (menor componente em Z); em piso, a mais alinhada ao eixo X (vermelho).
      def horizontal_grid_angle
        candidates = [arrow_base_angle, arrow_base_angle + 90.0].map do |degrees|
          radians = degrees.degrees
          vector = Geom::Vector3d.new(
            @frame.x_axis.x * Math.cos(radians) + @frame.y_axis.x * Math.sin(radians),
            @frame.x_axis.y * Math.cos(radians) + @frame.y_axis.y * Math.sin(radians),
            @frame.x_axis.z * Math.cos(radians) + @frame.y_axis.z * Math.sin(radians)
          )
          [degrees, vector.z.abs, -vector.x.abs]
        end
        candidates.min_by { |_degrees, z, x| [z.round(3), x] }.first
      end

      # Ângulo (graus, sistema 2D da paginação) da seta principal com rotação 0.
      def arrow_base_angle
        options = @metadata['documentation'] || {}
        options['direction_angle'].nil? ? 180.0 + @angle_degrees : options['direction_angle'].to_f
      end

      # Prévia: contornos das setas (espaço interno do grupo da paginação) com a união em [x, y].
      def arrow_preview(x, y, rotation:, count:, scale:)
        setup = arrow_setup(rotation: rotation, count: count, scale: scale)
        return [] unless setup

        setup[:directions].map do |radians|
          arrow_outline(x, y, radians, setup[:length]).map { |px, py| point(px, py) }
        end
      end

      # Seta de traço fino com ponta aberta em "V" (45°), como um único contorno 2D.
      def arrow_outline(x, y, radians, length)
        direction_x = Math.cos(radians)
        direction_y = Math.sin(radians)
        side_x = -direction_y
        side_y = direction_x
        w = length * 0.022                 # meia espessura do traço
        h = length * 0.28                  # comprimento de cada perna da ponta
        a = 1.0 / Math.sqrt(2.0)
        tip = length - Math.sqrt(2.0) * w  # a quina externa da ponta cai exatamente em `length`
        junction = tip - a * w * (2.0 + Math.sqrt(2.0))
        [
          [-w, -w], [junction, -w],
          [tip - a * h - a * w, -a * h + a * w], [tip - a * h + a * w, -a * h - a * w],
          [tip + Math.sqrt(2.0) * w, 0.0],
          [tip - a * h + a * w, a * h + a * w], [tip - a * h - a * w, a * h - a * w],
          [junction, w], [-w, w]
        ].map do |along, across|
          [x + direction_x * along + side_x * across, y + direction_y * along + side_y * across]
        end
      end

      # Ponto 2D da paginação -> ponto 3D nas coordenadas internas do grupo da paginação.
      def local_point(x, y)
        point(x, y)
      end

      private

      def automatic_direction_point(bounds, directions, length)
        # A junção fica no canto oposto às pontas, com folga para a largura das setas.
        offsets = directions.flat_map do |radians|
          dx = Math.cos(radians)
          dy = Math.sin(radians)
          side_x = -dy
          side_y = dx
          [[-0.022, -0.022], [0.78, -0.21], [1.0, 0.0],
           [0.78, 0.21], [-0.022, 0.022]].map do |along, across|
            [length * (dx * along + side_x * across), length * (dy * along + side_y * across)]
          end
        end
        size = [bounds[2] - bounds[0], bounds[3] - bounds[1]].min
        margin = size * 0.08 + 0.2 / 2.54 # + 2 mm de folga fixa, para a seta não encostar na parede
        x_offsets = offsets.map(&:first)
        y_offsets = offsets.map(&:last)
        x_min = bounds[0] + margin - x_offsets.min
        x_max = bounds[2] - margin - x_offsets.max
        y_min = bounds[1] + margin - y_offsets.min
        y_max = bounds[3] - margin - y_offsets.max
        x_direction = directions.sum { |radians| Math.cos(radians) }
        y_direction = directions.sum { |radians| Math.sin(radians) }
        x = x_direction.negative? ? x_max : x_min
        y = y_direction.negative? ? y_max : y_min
        x = (bounds[0] + bounds[2]) / 2.0 if x_min > x_max
        y = (bounds[1] + bounds[3]) / 2.0 if y_min > y_max
        [x, y]
      end

      TAG_NAME_HEIGHT = 15.0 / 2.54 # altura do nome na tag: 15 cm (A− / A+ multiplicam) → quadro ≈ 195 × 65 cm

      # Tag em "quadro": fundo claro semitransparente com cantos arredondados, barra vertical fina
      # à esquerda, NOME, FABRICANTE espaçado, linha fina e "dimensão | área". Fonte fina.
      # O tamanho da letra é fixo (não depende do texto) e o quadro cresce para a direita:
      # o canto superior esquerdo (`tag_corner`) fica parado quando o texto é editado.
      # O campo "Nome - Fabricante" é separado no hífen.
      def draw_tag(entities)
        report = @metadata['report'] || {}
        options = @metadata['documentation'] || {}
        label = options['label'].to_s.strip
        label = report['name'].to_s.strip if label.empty?
        label = 'Revestimento' if label.empty?
        name, brand = label.split(/\s+[-–—|]\s+/, 2).map(&:strip)
        dimensions = "#{format_dimension(report['width'].to_f)} × #{format_dimension(report['height'].to_f)} cm"
        area = report['area_m2'].to_f
        area_text = area.positive? ? "#{format('%.2f', area).tr('.', ',')} m²" : nil
        scale = options['tag_scale'].to_f.positive? ? options['tag_scale'].to_f.clamp(0.4, 3.0) : 1.0
        h = 1.0 # altura nominal do nome; o bloco inteiro é escalado no fim

        block = entities.add_group
        block.name = 'Texto da tag'
        e = block.entities
        # Coordenadas locais do bloco: x para a direita, y para cima, topo do texto em y = 0.
        # Projeto da tag (mesmas medidas do quadro), gravado na própria tag: a exportação para o
        # LayOut redesenha a tag com texto nativo do LayOut, nítido, por cima do viewport.
        texts = [{ 'text' => name.upcase, 'left' => 0.0, 'top' => 0.0, 'height' => h }]
        rects = []
        name_group = tag_text(e, name.upcase, h, left: 0.0, top: 0.0)
        # .to_f: bounds devolvem Length, que no JSON do projeto viraria texto com unidade ("0,29m")
        # e voltaria como 0 — era isso que zerava a largura da linha do meio no LayOut.
        bottom = name_group.bounds.min.y.to_f
        right = name_group.bounds.max.x.to_f
        if brand && !brand.empty?
          brand_height = h * 0.45
          texts << { 'text' => brand.upcase, 'left' => 0.0, 'top' => bottom - h * 0.3, 'height' => brand_height, 'spaced' => true }
          brand_group = tag_text(e, brand.upcase, brand_height, left: 0.0, top: bottom - h * 0.3,
                                                               tracking: brand_height * 0.32)
          bottom = brand_group.bounds.min.y.to_f
          right = [right, brand_group.bounds.max.x.to_f].max
        end
        rule_top = bottom - h * 0.38
        rule_thickness = h * 0.02
        info_height = h * 0.55
        info_top = rule_top - rule_thickness - h * 0.38
        texts << { 'text' => dimensions, 'left' => 0.0, 'top' => info_top, 'height' => info_height }
        dims_group = tag_text(e, dimensions, info_height, left: 0.0, top: info_top)
        info_bottom = dims_group.bounds.min.y.to_f
        info_right = dims_group.bounds.max.x.to_f
        if area_text
          separator_x = info_right + h * 0.8
          tag_rect(e, separator_x, info_top + info_height * 0.1, separator_x + h * 0.03, info_bottom - info_height * 0.1)
          rects << [separator_x, info_top + info_height * 0.1, separator_x + h * 0.03, info_bottom - info_height * 0.1]
          texts << { 'text' => area_text, 'left' => separator_x + h * 0.8, 'top' => info_top, 'height' => info_height }
          area_group = tag_text(e, area_text, info_height, left: separator_x + h * 0.8, top: info_top)
          info_bottom = [info_bottom, area_group.bounds.min.y.to_f].min
          info_right = area_group.bounds.max.x.to_f
        end
        content_right = [right, info_right].max
        tag_rect(e, 0.0, rule_top, content_right, rule_top - rule_thickness)
        bar_x = -h * 0.7
        tag_rect(e, bar_x, h * 0.05, bar_x + h * 0.05, info_bottom - h * 0.05)
        rects << [0.0, rule_top, content_right, rule_top - rule_thickness]
        rects << [bar_x, h * 0.05, bar_x + h * 0.05, info_bottom - h * 0.05]

        # Fundo: um pouco abaixo do texto (z negativo) para não se fundir com as faces do texto.
        pad_x = h * 0.8
        pad_y = h * 0.55
        left_edge = bar_x - pad_x
        right_edge = content_right + pad_x
        top_edge = h * 0.05 + pad_y
        bottom_edge = info_bottom - h * 0.05 - pad_y
        background = e.add_face(rounded_rect(left_edge, bottom_edge, right_edge, top_edge, h * 0.3, -0.015))
        if background
          background.material = tag_background
          background.back_material = tag_background
          background.edges.each { |edge| edge.hidden = true }
        end

        factor = TAG_NAME_HEIGHT * scale / h
        x_axis, y_axis, z_axis = tag_axes
        corner = tag_corner_point(options, x_axis, y_axis,
                                  (right_edge - left_edge) * factor, (top_edge - bottom_edge) * factor)
        # Escala só em X/Y: a folga em Z entre fundo e texto não cresce e nada afunda na peça.
        block.transformation = Geom::Transformation.axes(corner, x_axis, y_axis, z_axis) *
                               Geom::Transformation.scaling(factor, factor, 1.0) *
                               Geom::Transformation.translation([-left_edge, -top_edge, 0.0])
        # Grava na própria tag o seu canto (em coordenadas do quadro): o próximo redesenho
        # (ex.: editar o texto) recalcula a posição real, mesmo que a tag tenha sido movida à mão.
        block.set_attribute('RevestPlanner', 'tag_anchor_local', [left_edge, top_edge])
        block.set_attribute('RevestPlanner', 'tag_layout', JSON.generate(
          'box' => [left_edge, top_edge, right_edge, bottom_edge].map(&:to_f), 'radius' => h * 0.3,
          'texts' => texts.map { |item| item.transform_values { |value| value.is_a?(Numeric) ? value.to_f : value } },
          'rects' => rects.map { |rect| rect.map(&:to_f) }, 'font' => tag_font
        ))
      end

      # Canto superior esquerdo da tag. Se ainda não existe (tag nova, ou recém-posicionada com
      # "Posicionar tag"), centraliza o quadro no ponto escolhido e grava o canto — daí em diante
      # editar o texto só aumenta/diminui o quadro para a direita, sem tirar a tag do lugar.
      # Prioridade: 1) ponto recém-escolhido em "Posicionar tag" (centraliza nele);
      # 2) onde a tag está desenhada agora no modelo (gravado na própria tag);
      # 3) canto salvo nas opções; 4) centro da área paginada.
      def tag_corner_point(options, x_axis, y_axis, width, height)
        requested = options.delete('tag_point')
        stored = @displayed_tag_corner || options['tag_corner']
        if !requested.is_a?(Array) && stored.is_a?(Array) && stored.length >= 2
          corner = point(stored[0].to_f, stored[1].to_f)
        else
          x = requested.is_a?(Array) ? requested[0].to_f : (@min_x + @max_x) / 2.0
          y = requested.is_a?(Array) ? requested[1].to_f : (@min_y + @max_y) / 2.0
          corner = point(x, y).offset(x_axis, -width / 2.0).offset(y_axis, height / 2.0)
        end
        local = @frame.to_2d(corner)
        options['tag_corner'] = [local.x, local.y]
        corner
      end

      # Canto superior esquerdo da tag como ela está AGORA no modelo: aplica as transformações atuais
      # do grupo da tag e do quadro (que mudam se a pessoa mover a tag com a ferramenta Mover).
      def displayed_tag_corner(existing)
        return nil unless existing && existing.valid?

        block = existing.entities.grep(Sketchup::Group).find { |item| item.get_attribute('RevestPlanner', 'tag_anchor_local') }
        anchor = block && block.get_attribute('RevestPlanner', 'tag_anchor_local')
        return nil unless anchor.is_a?(Array) && anchor.length >= 2

        actual = Geom::Point3d.new(anchor[0].to_f, anchor[1].to_f, 0.0)
                              .transform(existing.transformation * block.transformation)
        local = @frame.to_2d(actual)
        [local.x, local.y]
      end

      # Se as setas foram movidas à mão, o novo ponto de união passa a ser o ponto movido.
      def capture_moved_arrows(existing, options)
        return unless existing && existing.valid? && !existing.transformation.identity?

        junction = existing.get_attribute('RevestPlanner', 'arrow_junction')
        return unless junction.is_a?(Array) && junction.length >= 2

        moved = point(junction[0].to_f, junction[1].to_f).transform(existing.transformation)
        local = @frame.to_2d(moved)
        options['direction_point'] = [local.x, local.y]
      end

      # Eixos de leitura da tag: X da tag na direção "horizontal" da grade (piso: a mais próxima do
      # eixo vermelho; parede: a deitada), Y para cima na leitura e Z voltado para quem olha.
      def tag_axes
        grid = [arrow_base_angle, arrow_base_angle + 90.0].map do |degrees|
          radians = degrees.degrees
          vector = Geom::Vector3d.new(
            @frame.x_axis.x * Math.cos(radians) + @frame.y_axis.x * Math.sin(radians),
            @frame.x_axis.y * Math.cos(radians) + @frame.y_axis.y * Math.sin(radians),
            @frame.x_axis.z * Math.cos(radians) + @frame.y_axis.z * Math.sin(radians)
          )
          vector.normalize
        end
        normal = @frame.normal.clone.normalize
        if normal.z.abs > 0.7
          # Piso / forro: lido de cima (ou de baixo, no forro).
          z_axis = normal.z.negative? ? normal.reverse : normal
          x_axis = grid.max_by { |vector| vector.x.abs }
          x_axis = x_axis.reverse if x_axis.x.negative?
          y_axis = (z_axis * x_axis).normalize
        else
          # Parede: texto em pé, de frente para o lado da face.
          z_axis = normal
          y_axis = grid.max_by { |vector| vector.z.abs }
          y_axis = y_axis.reverse if y_axis.z.negative?
          x_axis = (y_axis * z_axis).normalize
        end
        [x_axis, y_axis, z_axis]
      end

      def rounded_rect(x1, y1, x2, y2, radius, z)
        radius = [radius, (x2 - x1) / 2.0, (y2 - y1) / 2.0].min
        corners = [[x2 - radius, y2 - radius, 0], [x1 + radius, y2 - radius, 90],
                   [x1 + radius, y1 + radius, 180], [x2 - radius, y1 + radius, 270]]
        corners.flat_map do |cx, cy, start|
          (0..6).map do |step|
            angle = (start + step * 15).degrees
            [cx + radius * Math.cos(angle), cy + radius * Math.sin(angle), z]
          end
        end
      end


      # Uma linha de texto 3D (plana) com o canto superior esquerdo em (left, top).
      # `tracking` afasta as letras (o add_3d_text não tem espaçamento entre letras).
      def tag_text(entities, string, height, left:, top:, bold: false, tracking: 0.0)
        group = entities.add_group
        if tracking.zero?
          group.entities.add_3d_text(string, TextAlignLeft, tag_font, bold, false, height, 0.0, 0.0, true, 0.0)
        else
          cursor = 0.0
          string.each_char do |char|
            if char.strip.empty?
              cursor += height * 0.4 + tracking
              next
            end
            glyph = group.entities.add_group
            glyph.entities.add_3d_text(char, TextAlignLeft, tag_font, bold, false, height, 0.0, 0.0, true, 0.0)
            bounds = glyph.bounds
            glyph.transform!(Geom::Transformation.translation([cursor - bounds.min.x, 0.0, 0.0]))
            cursor += bounds.width + tracking
            glyph.explode
          end
        end
        group.entities.grep(Sketchup::Face).each do |face|
          face.material = tag_ink
          face.back_material = tag_ink
        end
        # Sem contorno: as arestas das letras levavam a cor do estilo (azul) e engrossavam a fonte.
        group.entities.grep(Sketchup::Edge).each { |edge| edge.hidden = true }
        bounds = group.bounds
        group.transform!(Geom::Transformation.translation([left - bounds.min.x, top - bounds.max.y, 0.0]))
        group
      end

      def tag_rect(entities, x1, y1, x2, y2)
        face = entities.add_face([x1, y1, 0.0], [x2, y1, 0.0], [x2, y2, 0.0], [x1, y2, 0.0])
        return unless face

        face.material = tag_ink
        face.back_material = tag_ink
        face.edges.each { |edge| edge.hidden = true }
      end

      # Fonte geométrica, como na referência, quando instalada; senão Arial.
      def tag_font
        @tag_font ||= begin
          folders = [File.join(ENV['WINDIR'] || 'C:/Windows', 'Fonts'),
                     File.join(ENV['LOCALAPPDATA'].to_s, 'Microsoft', 'Windows', 'Fonts'),
                     '/Library/Fonts', File.join(Dir.home, 'Library', 'Fonts')]
          candidates = [['Montserrat', %w[Montserrat-Regular.ttf Montserrat-Medium.ttf]],
                        ['Century Gothic', %w[GOTHIC.TTF gothic.ttf]]]
          found = candidates.find do |_family, files|
            folders.any? { |folder| files.any? { |file| File.exist?(File.join(folder, file)) } }
          end
          found ? found.first : 'Arial'
        rescue StandardError
          'Arial'
        end
      end

      def format_dimension(value)
        format('%.2f', value).sub(/0+\z/, '').sub(/\.\z/, '').tr('.', ',')
      end
    end
  end
end
