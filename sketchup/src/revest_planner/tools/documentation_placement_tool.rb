# frozen_string_literal: true

require 'json'

module RevestPlanner
  module Tools
    class DocumentationPlacementTool
      def initialize(controller, group, mode)
        @controller = controller
        @group = group
        @mode = mode
        @input = Sketchup::InputPoint.new
        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        face = Sketchup.active_model.find_entity_by_persistent_id(data['face_pid'].to_i)
        transformation = Geom::Transformation.new(Array(data['transformation']))
        frame = SketchupAdapter::PlaneFrame.from_face(face, transformation)
        @plane = [frame.origin, frame.normal]
      end

      def activate
        if @mode == 'start'
          @temporarily_hidden = @group.entities.grep(Sketchup::Group).select do |child|
            child.get_attribute('RevestPlanner', 'documentation_key')
          end.to_h { |child| [child, child.hidden?] }
          @temporarily_hidden.each_key { |child| child.hidden = true }
        end
        prompt
      end

      def deactivate(view)
        @temporarily_hidden&.each do |child, was_hidden|
          child.hidden = was_hidden if child.valid?
        end
        view.invalidate
        @controller.documentation_prompt(nil)
      end

      def onMouseMove(_flags, x, y, view)
        @input.pick(view, x, y)
        @hover_point = projected_point(view, x, y)
        view.tooltip = @input.tooltip
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        @input.pick(view, x, y)
        clicked = projected_point(view, x, y)
        return ::UI.beep unless clicked

        if @mode == 'start'
          face = picked_piece_face(view, x, y)
          return ::UI.beep unless face

          @controller.finish_documentation_pick(@group, @mode, clicked, face)
        else
          @controller.finish_documentation_pick(@group, @mode, clicked, nil)
        end
      end

      def onCancel(_reason, _view)
        @controller.cancel_documentation_pick
      end

      def draw(view)
        return unless @hover_point

        view.draw_points([@hover_point], 10, 3, Sketchup::Color.new(206, 214, 41))
      end

      private

      def prompt
        text = case @mode
               when 'start' then 'Clique na peça inicial da paginação. Esc cancela.'
               else 'Clique sobre a paginação para posicionar a tag. Esc cancela.'
               end
        Sketchup.set_status_text(text)
        @controller.documentation_prompt(text)
      end

      def projected_point(view, x, y)
        Geom.intersect_line_plane(view.pickray(x, y), @plane) || (@input.position if @input.valid?)
      end

      def picked_piece_face(view, x, y)
        helper = view.pick_helper
        helper.do_pick(x, y)
        helper.count.times do |index|
          path = helper.path_at(index)
          next unless path && path.include?(@group)

          face = path.reverse.find do |entity|
            entity.is_a?(Sketchup::Face) && entity.get_attribute('RevestPlanner', 'piece_id')
          end
          return face if face
        end
        nil
      end
    end
  end
end
