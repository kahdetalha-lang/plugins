# frozen_string_literal: true

module RevestPlanner
  module Tools
    class PreviewTool
      # Mantém o desenho afastado o suficiente da face para evitar z-fighting
      # quando a câmera está distante. O sinal é escolhido em direção à câmera.
      PREVIEW_OFFSET = 2.0 / 25.4
      def initialize(controller)
        @controller = controller
        @input = Sketchup::InputPoint.new
        @cached_result_id = nil
        @cached_geometry = nil
      end

      def activate
        Sketchup.set_status_text('Ajuste a paginação no painel e clique em Gerar.')
      end

      # O SketchUp suspende a ferramenta ativa enquanto o botão central aciona
      # temporariamente a órbita. Força o redesenho assim que a órbita termina.
      def resume(view)
        view.invalidate
      end

      def onMouseWheel(_flags, _delta, _x, _y, view)
        view.invalidate
        false
      end

      def draw(view)
        adapter = @controller.adapter
        result = @controller.result
        return unless adapter && result

        view.line_width = 1
        elevation = preview_elevation(view, adapter)
        preview_geometry(adapter, result, elevation).each_with_index do |points, index|
          view.drawing_color = index.zero? ?
            Sketchup::Color.new(37, 99, 235) : Sketchup::Color.new(239, 68, 68)
          points.each_slice(2048) { |batch| view.draw(GL_LINES, batch) }
        end
        if @controller.anchor_mode?
          draw_start_piece(view, adapter, elevation, hover_start_piece)
        else
          draw_start_piece(view, adapter, elevation, @controller.chosen_start_piece)
        end
        draw_anchor(view, adapter)
        draw_hover_anchor(view) if @controller.anchor_mode? || @controller.rotation_mode?
      end

      def onMouseMove(_flags, x, y, view)
        return unless @controller.anchor_mode? || @controller.rotation_mode?

        @input.pick(view, x, y)
        @hover_ray = view.pickray(x, y)
        if @controller.rotation_mode? && @input.valid?
          @controller.update_rotation(@input.position)
          view.tooltip = 'Clique para confirmar a rotação'
        else
          view.tooltip = 'Definir início da paginação'
        end
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        return unless @input.valid?

        if @controller.rotation_mode?
          @controller.finish_rotation
        elsif @controller.anchor_mode?
          # O ponto pode "grudar" num canto da parede; o raio do mouse diz de que lado ele estava.
          @controller.set_anchor(@input.position, view.pickray(x, y))
        end
        view.invalidate
      end

      def onCancel(_reason, _view)
        if @controller.rotation_mode?
          @controller.cancel_rotation
        elsif @controller.anchor_mode?
          @controller.cancel_anchor
        else
          @controller.close
        end
      end

      private

      # A geometria da prévia só muda quando um novo resultado é calculado.
      # Mantê-la em cache evita reconstruir milhares de segmentos sempre que
      # o SketchUp redesenha a viewport durante zoom, órbita ou movimentação.
      def preview_geometry(adapter, result, elevation)
        cache_key = [result.object_id, elevation.positive?]
        return @cached_geometry if @cached_result_id == cache_key && @cached_geometry

        @cached_result_id = cache_key
        batches = [[], []]
        result.pieces.each do |piece|
          points = boundary_segments(piece.fragments).flat_map do |first, second|
            [adapter.frame.to_3d(first, elevation), adapter.frame.to_3d(second, elevation)]
          end
          batches[piece.classification == :whole ? 0 : 1].concat(points)
        end
        @cached_geometry = batches
      end

      def preview_elevation(view, adapter)
        toward_camera = adapter.frame.origin.vector_to(view.camera.eye)
        toward_camera.dot(adapter.frame.normal) >= 0.0 ? PREVIEW_OFFSET : -PREVIEW_OFFSET
      end

      # Fragmentos adjacentes são consequência da triangulação da face-alvo.
      # Uma aresta presente duas vezes é interna e não faz parte da peça.
      def boundary_segments(fragments)
        original = fragments.flat_map do |fragment|
          fragment.points.each_with_index.map do |point, index|
            [point, fragment.points[(index + 1) % fragment.points.length]]
          end
        end
        return original if fragments.length == 1

        # Uma mesma divisão pode chegar como um segmento longo de um lado e
        # vários segmentos curtos do outro. Primeiro quebramos todos nos pontos
        # coincidentes; depois, os trechos internos aparecem duas vezes.
        endpoints = original.flat_map { |first, second| [first, second] }.sort_by(&:x)
        atomic = original.flat_map do |first, second|
          cuts = [0.0, 1.0]
          min_x, max_x = [first.x, second.x].minmax
          index = endpoints.bsearch_index { |point| point.x >= min_x - 1.0e-5 } || endpoints.length
          while index < endpoints.length && endpoints[index].x <= max_x + 1.0e-5
            parameter = point_on_segment_parameter(endpoints[index], first, second)
            cuts << parameter if parameter
            index += 1
          end
          cuts.sort.uniq.each_cons(2).map do |from, to|
            vector = second - first
            [first + vector * from, first + vector * to]
          end
        end

        grouped = atomic.group_by { |first, second| segment_key(first, second) }
        grouped.values.select(&:one?).map(&:first)
      end

      def point_on_segment_parameter(point, first, second)
        vector = second - first
        length_squared = (vector.x * vector.x) + (vector.y * vector.y)
        return nil if length_squared <= 1.0e-12

        relative = point - first
        return nil if relative.cross(vector).abs > 1.0e-6

        parameter = ((relative.x * vector.x) + (relative.y * vector.y)) / length_squared
        parameter.between?(-1.0e-7, 1.0000001) ? [[parameter, 0.0].max, 1.0].min : nil
      end

      def segment_key(first, second)
        a = [first.x.round(6), first.y.round(6)]
        b = [second.x.round(6), second.y.round(6)]
        (a <=> b) == 1 ? [b, a] : [a, b]
      end

      def draw_anchor(view, adapter)
        point = @controller.anchor_point
        return unless point

        size = @controller.anchor_axis_size
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(239, 68, 68)
        view.draw(GL_LINES, [point, point.offset(adapter.frame.x_axis, size)])
        view.drawing_color = Sketchup::Color.new(34, 197, 94)
        view.draw(GL_LINES, [point, point.offset(adapter.frame.y_axis, size)])
        view.draw_points([point], 14, 3, Sketchup::Color.new(14, 165, 233))
      end

      # Peça que vai ser a inicial (a mesma que a documentação hachura): destaque amarelo.
      def hover_start_piece
        return nil unless @input.valid? && @hover_ray

        key = [@input.position.to_a.map { |value| value.round(4) }, @hover_ray[1].to_a.map { |value| value.round(5) }]
        return @hover_piece if @hover_key == key

        @hover_key = key
        @hover_piece = @controller.hover_start_piece(@input.position, @hover_ray)
      end

      def draw_start_piece(view, adapter, elevation, outline)
        return unless outline && outline.length >= 3

        points = outline.map { |point| adapter.frame.to_3d(point, elevation) }
        view.drawing_color = Sketchup::Color.new(206, 214, 41, 90)
        view.draw(GL_POLYGON, points)
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(169, 176, 20)
        view.draw(GL_LINE_LOOP, points)
        view.line_width = 1
      end

      def draw_hover_anchor(view)
        return unless @input.valid?

        view.draw_points([@input.position], 10, 3, Sketchup::Color.new(245, 158, 11))
      end
    end
  end
end
