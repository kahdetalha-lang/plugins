# frozen_string_literal: true

module RevestPlanner
  module Tools
    class FacePickerTool
      def initialize(controller)
        @controller = controller
        @input = Sketchup::InputPoint.new
        @hover_face = nil
        @hover_path = nil
        @hover_transformation = Geom::Transformation.new
      end

      def activate
        Sketchup.set_status_text('Clique na face que receberá a paginação.')
      end

      def onMouseMove(_flags, x, y, view)
        @input.pick(view, x, y)
        @hover_face, @hover_path, @hover_transformation = picked_face(view, x, y)
        view.tooltip = @input.tooltip
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        face, path, = picked_face(view, x, y)
        return ::UI.beep unless face

        @controller.select_face(face, path)
      end

      def draw(view)
        return unless @hover_face && @hover_face.valid?

        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(206, 214, 41)
        [@hover_face].each do |face|
          face.loops.each do |loop|
            points = loop.vertices.map { |vertex| vertex.position.transform(@hover_transformation) }
            view.draw(GL_LINE_LOOP, points)
          end
        end
      end

      private

      # PickHelper devolve o caminho completo até entidades dentro de grupos e
      # componentes. Usar esse caminho permite realçar e selecionar a face no
      # contexto do modelo sem obrigar o usuário a abrir o contêiner.
      def picked_face(view, x, y)
        helper = view.pick_helper
        helper.do_pick(x, y)

        helper.count.times do |index|
          path = helper.path_at(index)
          next unless path

          face = path.reverse.find { |entity| entity.is_a?(Sketchup::Face) }
          next unless face

          transformation = if path.length > 1
                             Sketchup::InstancePath.new(path).transformation
                           else
                             Geom::Transformation.new
                           end
          return [face, path, transformation]
        rescue ArgumentError
          next
        end

        [nil, nil, Geom::Transformation.new]
      end
    end
  end
end
