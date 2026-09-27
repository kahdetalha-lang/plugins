# frozen_string_literal: true

require 'json'

module RevestPlanner
  module Tools
    # Ferramenta das setas de sentido da paginação, com encaixe automático na peça sob o mouse:
    #   - 1 ou 2 setas: perto de um canto (90°) da peça, a união vai para o canto e as setas
    #     seguem as arestas para dentro da peça (1 seta: a aresta que o mouse está seguindo);
    #   - 3 setas: perto de uma aresta, a principal entra na peça e as outras correm pela aresta;
    #   - longe de cantos/arestas: as setas seguem o mouse livremente.
    # Um clique posiciona. Ajustes finos depois, pelo painel (Girar 90° / Inverter).
    #
    # Todas as contas são feitas no espaço interno do grupo da paginação — o mesmo em que o
    # DocumentationWriter desenha —, então funciona também com a paginação dentro de outros grupos.
    class ArrowPlacementTool
      PREVIEW_COLOR = Sketchup::Color.new(118, 28, 44)
      PROMPT = 'Aproxime as setas de um canto (ou aresta, com 3 setas) de uma peça: elas se ajustam sozinhas. ' \
               'Clique para posicionar. Esc cancela.'
      SNAP_RATIO = 0.35    # raio de encaixe, em fração do menor lado da peça
      INSET_RATIO = 0.15   # afastamento da união em relação ao canto/aresta, em fração do comprimento da seta
      ARROW_CLEARANCE = 0.2 / 2.54 # + 2 mm de folga fixa, para a seta não encostar na parede
      KEY_NAMES = { VK_LEFT => 'left', VK_RIGHT => 'right', 9 => 'right', VK_UP => 'up', VK_DOWN => 'down' }.freeze

      def initialize(controller, group)
        @controller = controller
        @group = group
      end

      def activate
        model = Sketchup.active_model
        data = JSON.parse(@group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        @writer = SketchupAdapter::DocumentationWriter.new(model: model, group: @group, metadata: data)
        @rotation = SketchupAdapter::DocumentationWriter.arrow_rotation(options)
        @count = SketchupAdapter::DocumentationWriter.arrow_count(options)
        @scale = SketchupAdapter::DocumentationWriter.arrow_scale(options)
        @base = @writer.arrow_base_angle
        setup = @writer.arrow_setup(rotation: @rotation, count: @count, scale: @scale)
        @inset = (setup ? setup[:length] * INSET_RATIO : 0.0) + ARROW_CLEARANCE
        @pieces = @writer.piece_outlines_2d.map { |points| prepare_piece(points) }.compact
        @to_world = world_transformation(model)
        @to_local = @to_world.inverse
        @plane = [@writer.local_point(0.0, 0.0).transform(@to_world), @writer.frame.normal.transform(@to_world).normalize]
        @controller.arrow_tool_started(self)
        update_status
      rescue StandardError => error
        @failed = true
        ::UI.messagebox("REVEST: não foi possível iniciar a ferramenta das setas.\n#{error.message}")
        Sketchup.send_action('selectSelectionTool:')
      end

      def deactivate(view)
        @controller.arrow_tool_finished(self)
        view.invalidate
        @controller.documentation_prompt(nil)
      end

      def resume(view)
        update_status
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        return if @failed

        mouse = point_2d(view, x, y)
        @placement = mouse && (snap(mouse) || { point: mouse, rotation: @rotation, snapped: false })
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, _view)
        return if @failed
        return ::UI.beep unless @placement

        @controller.place_arrows(@group, point: @placement[:point], rotation: @placement[:rotation],
                                         count: @count, scale: @scale)
      end

      # Teclado (opcional): ← → / Tab giram quando as setas estão soltas; ↑ ↓ mudam a quantidade.
      def onKeyDown(key, _repeat, _flags, view)
        name = KEY_NAMES[key]
        return false unless name

        handle_key(name, view)
        true
      end

      # Também chamado pelo painel (HtmlDialog), quando o foco do teclado está nele.
      def handle_key(name, view = Sketchup.active_model.active_view)
        case name
        when 'right' then @rotation = (@rotation - 90) % 360
        when 'left' then @rotation = (@rotation + 90) % 360
        when 'up' then @count = [@count + 1, 3].min
        when 'down' then @count = [@count - 1, 1].max
        when 'escape' then return Sketchup.send_action('selectSelectionTool:')
        else return false
        end
        update_status
        view.invalidate
        true
      end

      def onCancel(_reason, _view)
        Sketchup.send_action('selectSelectionTool:')
      end

      def draw(view)
        return unless @placement

        x, y = @placement[:point]
        view.drawing_color = PREVIEW_COLOR
        view.line_width = @placement[:snapped] ? 3 : 2
        view.line_stipple = ''
        @writer.arrow_preview(x, y, rotation: @placement[:rotation], count: @count, scale: @scale).each do |outline|
          view.draw(GL_LINE_LOOP, outline.map { |pt| pt.transform(@to_world) })
        end
        return unless @placement[:snapped] && @placement[:anchor]

        # Marca o canto/aresta onde as setas encaixaram.
        view.draw_points([@writer.local_point(*@placement[:anchor]).transform(@to_world)], 10, 1, PREVIEW_COLOR)
      end

      private

      # ---------- encaixe automático ----------

      def prepare_piece(points)
        points = points.each_with_object([]) { |pt, memo| memo << pt unless memo.last && dist(memo.last, pt) < 1.0e-6 }
        return nil if points.length < 3

        xs = points.map(&:first)
        ys = points.map(&:last)
        size = [xs.max - xs.min, ys.max - ys.min].min
        ccw = signed_area(points).positive?
        { points: points, size: size, ccw: ccw, bounds: [xs.min, ys.min, xs.max, ys.max] }
      end

      def snap(mouse)
        piece = @pieces.find { |candidate| inside?(mouse, candidate) }
        return nil unless piece

        @count == 3 ? snap_to_edge(mouse, piece) : snap_to_corner(mouse, piece)
      end

      def snap_to_corner(mouse, piece)
        points = piece[:points]
        radius = piece[:size] * SNAP_RATIO
        best = nil
        points.each_with_index do |corner, index|
          distance = dist(mouse, corner)
          next if distance > radius || (best && distance >= best[:distance])

          e1 = unit(sub(points[index - 1], corner))
          e2 = unit(sub(points[(index + 1) % points.length], corner))
          next unless e1 && e2 && dot(e1, e2).abs < 0.05 # só cantos em ângulo reto

          best = { distance: distance, corner: corner, e1: e1, e2: e2 }
        end
        return nil unless best

        e1 = best[:e1]
        e2 = best[:e2]
        main = if @count == 1
                 offset = sub(mouse, best[:corner])
                 dot(offset, e1) >= dot(offset, e2) ? e1 : e2
               else
                 # O conjunto de 2 setas é {principal, principal − 90°}.
                 dot(e2, [e1[1], -e1[0]]) > 0.9 ? e1 : e2
               end
        junction = add(best[:corner], scale_vec(add(e1, e2), @inset))
        { point: junction, rotation: rotation_for(main), snapped: true, anchor: best[:corner] }
      end

      def snap_to_edge(mouse, piece)
        points = piece[:points]
        radius = piece[:size] * SNAP_RATIO
        best = nil
        points.each_with_index do |start, index|
          finish = points[(index + 1) % points.length]
          direction = unit(sub(finish, start))
          next unless direction

          along = dot(sub(mouse, start), direction).clamp(0.0, dist(start, finish))
          foot = add(start, scale_vec(direction, along))
          distance = dist(mouse, foot)
          next if distance > radius || (best && distance >= best[:distance])

          best = { distance: distance, foot: foot, direction: direction }
        end
        return nil unless best

        d = best[:direction]
        inward = piece[:ccw] ? [-d[1], d[0]] : [d[1], -d[0]]
        junction = add(best[:foot], scale_vec(inward, @inset))
        { point: junction, rotation: rotation_for(inward), snapped: true, anchor: best[:foot] }
      end

      # Rotação (múltiplo de 90°) que faz a seta principal apontar em `vector`.
      def rotation_for(vector)
        wanted = Math.atan2(vector[1], vector[0]).radians - @base
        ((wanted / 90.0).round * 90) % 360
      end

      def inside?(point, piece)
        bounds = piece[:bounds]
        return false if point[0] < bounds[0] || point[0] > bounds[2] || point[1] < bounds[1] || point[1] > bounds[3]

        inside = false
        points = piece[:points]
        points.each_with_index do |a, index|
          b = points[index - 1]
          next unless (a[1] > point[1]) != (b[1] > point[1])

          cross_x = (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]
          inside = !inside if point[0] < cross_x
        end
        inside
      end

      def signed_area(points)
        points.each_with_index.sum do |a, index|
          b = points[(index + 1) % points.length]
          a[0] * b[1] - b[0] * a[1]
        end / 2.0
      end

      def sub(a, b)
        [a[0] - b[0], a[1] - b[1]]
      end

      def add(a, b)
        [a[0] + b[0], a[1] + b[1]]
      end

      def scale_vec(a, factor)
        [a[0] * factor, a[1] * factor]
      end

      def dot(a, b)
        a[0] * b[0] + a[1] * b[1]
      end

      def dist(a, b)
        Math.hypot(a[0] - b[0], a[1] - b[1])
      end

      def unit(vector)
        length = Math.hypot(vector[0], vector[1])
        length < 1.0e-9 ? nil : [vector[0] / length, vector[1] / length]
      end

      # ---------- geral ----------

      def update_status
        text = "#{PROMPT}   [#{@count} seta#{'s' if @count > 1}]"
        Sketchup.set_status_text(text)
        @controller.documentation_prompt(text)
      end

      # Espaço interno da paginação -> mundo. Se estivermos editando dentro dela, soma as
      # transformações do caminho até ela; senão, contexto ativo * grupo.
      def world_transformation(model)
        path = Array(model.active_path)
        index = path.index(@group)
        return model.edit_transform * @group.transformation unless index

        path[0..index].inject(Geom::Transformation.new) { |memo, entity| memo * entity.transformation }
      end

      # Ponto do mouse -> coordenadas 2D da paginação (interseção do raio do mouse com o plano).
      def point_2d(view, x, y)
        world = Geom.intersect_line_plane(view.pickray(x, y), @plane)
        return nil unless world

        local = @writer.frame.to_2d(world.transform(@to_local))
        [local.x, local.y]
      end
    end
  end
end
