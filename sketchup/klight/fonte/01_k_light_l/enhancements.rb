module KahDetalha
  module KLight
    SETTINGS_BY_KIND = {
      'spot' => %w[angle_deg length_cm layers alpha_max curve_exp preset rgb_custom],
      'backlight' => %w[halo_radius_cm halo_falloff alpha_max preset rgb_custom],
      'ribbon' => %w[width_cm layers alpha_max curve_exp offset_mm direction vertical preset rgb_custom]
    }.freeze

    def self.klight_groups(selection = Sketchup.active_model.selection)
      selection.grep(Sketchup::Group).select do |group|
        group.valid? && group.get_attribute(ATTR_DICT, 'version')
      end
    end

    def self.light_kind(group)
      group.get_attribute(ATTR_DICT, 'kind', 'ribbon').to_s
    end

    def self.settings_from_group(group)
      kind = light_kind(group)
      keys = SETTINGS_BY_KIND[kind] || SETTINGS_BY_KIND['ribbon']
      values = keys.each_with_object({}) do |key, memo|
        memo[key.to_sym] = group.get_attribute(ATTR_DICT, key, nil)
      end
      values[:kind] = kind
      values[:rgb_custom] = Core.numeric_triplet(values[:rgb_custom])
      values
    end

    def self.copy_light_settings
      groups = klight_groups
      unless groups.length == 1
        UI.messagebox('K.Light: selecione somente uma luz como referência.')
        return
      end
      @copied_light_settings = settings_from_group(groups.first)
      UI.messagebox("K.Light: configurações de #{light_kind(groups.first)} copiadas.")
    end

    def self.register_settings_brush_command(command, icons_dir)
      @settings_brush_command = command
      @settings_brush_icons_dir = icons_dir
    end

    def self.settings_brush_icon(stage)
      return unless @settings_brush_command && @settings_brush_icons_dir
      name = stage == :paste ? 'paste' : 'copy'
      @settings_brush_command.small_icon = File.join(@settings_brush_icons_dir, "k_settings_#{name}_24.png")
      @settings_brush_command.large_icon = File.join(@settings_brush_icons_dir, "k_settings_#{name}_32.png")
      @settings_brush_command.tooltip = stage == :paste ?
        'K.Light — Aplicar configurações (ESC para sair)' :
        'K.Light — Escolher luz de referência'
    rescue StandardError
      nil
    end

    def self.start_settings_brush
      Sketchup.active_model.select_tool(LightSettingsBrushTool.new)
    end

    class LightSettingsBrushTool
      def initialize
        @settings = nil
        @source = nil
        @hover = nil
        icons = File.join(File.dirname(__FILE__), 'icons')
        @copy_cursor = UI.create_cursor(File.join(icons, 'k_settings_copy_32.png'), 2, 29) rescue nil
        @paste_cursor = UI.create_cursor(File.join(icons, 'k_settings_paste_32.png'), 5, 27) rescue nil
      end

      def activate
        KLight.settings_brush_icon(:copy)
        Sketchup.status_text = 'K.Light Conta-gotas: clique na luz cujas configurações deseja copiar — ESC cancela'
      end

      def deactivate(view)
        KLight.settings_brush_icon(:copy)
        view.invalidate
      end

      def onSetCursor
        cursor = @settings ? @paste_cursor : @copy_cursor
        cursor ? UI.set_cursor(cursor) : false
      end

      def light_at(view, x, y)
        picker = view.pick_helper
        picker.do_pick(x, y)
        (0...picker.count).each do |index|
          path = picker.path_at(index) rescue []
          group = path.reverse.find do |entity|
            entity.is_a?(Sketchup::Group) && entity.valid? &&
              entity.get_attribute(ATTR_DICT, 'version')
          end
          return group if group
        end
        nil
      end

      def onMouseMove(_flags, x, y, view)
        @hover = light_at(view, x, y)
        if @settings && @hover && KLight.light_kind(@hover) != @settings[:kind]
          Sketchup.status_text = "K.Light Balde: esta luz não é compatível; escolha um #{@settings[:kind]}"
        elsif @settings
          Sketchup.status_text = 'K.Light Balde: clique nas luzes de destino — ESC encerra'
        else
          Sketchup.status_text = 'K.Light Conta-gotas: clique na luz de referência'
        end
        view.invalidate
      end

      def onLButtonUp(_flags, x, y, view)
        group = light_at(view, x, y)
        unless group
          Sketchup.status_text = 'K.Light: nenhuma luz encontrada nesse ponto.'
          return
        end

        unless @settings
          @source = group
          @settings = KLight.settings_from_group(group)
          KLight.instance_variable_set(:@copied_light_settings, @settings.dup)
          KLight.settings_brush_icon(:paste)
          Sketchup.status_text = "K.Light Balde: configurações de #{@settings[:kind]} copiadas; clique nas luzes de destino"
          onSetCursor
          return
        end

        if KLight.light_kind(group) != @settings[:kind]
          Sketchup.status_text = "K.Light: tipos incompatíveis; escolha uma luz #{@settings[:kind]}."
          return
        end

        model = view.model
        model.start_operation('K.Light — Aplicar Configurações', true)
        unless KLight.apply_settings_to_group(model, group, @settings)
          model.abort_operation
          Sketchup.status_text = 'K.Light: não foi possível aplicar nessa luz.'
          return
        end
        model.commit_operation
        model.selection.clear
        model.selection.add(group) if group.valid?
        model.active_view.invalidate
        Sketchup.status_text = 'K.Light: configurações aplicadas. Clique em outra luz ou pressione ESC.'
      rescue StandardError => error
        model.abort_operation rescue nil
        UI.messagebox("K.Light: não foi possível aplicar as configurações.\n#{error.message}")
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end
    end

    def self.world_spot_data(group)
      apex_values = Core.numeric_triplet(group.get_attribute(ATTR_DICT, 'apex', nil))
      normal_values = Core.numeric_triplet(group.get_attribute(ATTR_DICT, 'normal', nil))
      return nil unless apex_values && normal_values
      tr = group.transformation
      apex = Geom::Point3d.new(*apex_values).transform(tr)
      normal = Geom::Vector3d.new(*normal_values).transform(tr)
      return nil if normal.length <= 1e-9
      normal.normalize!
      [apex, normal]
    end

    def self.ribbon_data(group, model)
      point_values = Core.numeric_point_list(group.get_attribute(ATTR_DICT, 'path_pts', nil))
      return nil unless point_values
      tr = group.transformation
      points = point_values.map { |point| Geom::Point3d.new(*point).transform(tr) }
      normal_values = Core.numeric_triplet(group.get_attribute(ATTR_DICT, 'face_normal', nil))
      normal = normal_values && Geom::Vector3d.new(*normal_values).transform(tr)
      normal = nil if normal && normal.length <= 1e-9
      normal.normalize! if normal
      prep = Led.ribbon_prep_from_world_points(model, points, normal)
      return nil unless prep
      prep[:smart_contour] = true if group.get_attribute(ATTR_DICT, 'smart_contour', false) == true
      prep
    end

    def self.normalized_params(settings)
      params = settings.dup
      params.delete(:kind)
      params[:preset] = params[:preset].to_s
      params[:rgb_custom] = Core.numeric_triplet(params[:rgb_custom]) unless params[:rgb_custom].is_a?(Array)
      params
    end

    def self.write_spot_attributes(group, apex, normal, params, target = nil)
      group.set_attribute(ATTR_DICT, 'kind', 'spot')
      group.set_attribute(ATTR_DICT, 'apex', JSON.generate([apex.x.to_f, apex.y.to_f, apex.z.to_f]))
      group.set_attribute(ATTR_DICT, 'normal', JSON.generate([normal.x.to_f, normal.y.to_f, normal.z.to_f]))
      if target
        group.set_attribute(ATTR_DICT, 'target', JSON.generate([target.x.to_f, target.y.to_f, target.z.to_f]))
      else
        group.delete_attribute(ATTR_DICT, 'target') rescue nil
      end
      SETTINGS_BY_KIND['spot'].each do |key|
        value = params[key.to_sym]
        value = JSON.generate(value) if key == 'rgb_custom'
        group.set_attribute(ATTR_DICT, key, value)
      end
      group.set_attribute(ATTR_DICT, 'version', PLUGIN_VERSION)
    end

    def self.apply_settings_to_group(model, group, settings, preview: false)
      kind = light_kind(group)
      params = normalized_params(settings)
      case kind
      when 'spot'
        data = world_spot_data(group)
        return false unless data
        apex, normal = data
        normal = normal.reverse if params.delete(:invert_direction)
        target_values = Core.numeric_triplet(group.get_attribute(ATTR_DICT, 'target', nil))
        target = target_values && Geom::Point3d.new(*target_values).transform(group.transformation)
        group.transformation = Geom::Transformation.new
        result = Spot.rebuild_spot(model, group, apex, normal, params, nil, preview: preview)
        write_spot_attributes(group, apex, normal, params, target)
        result && true
      when 'backlight'
        faces = Letreiro.find_backlight_source_faces(model, group)
        if faces.empty?
          Letreiro.update_backlight_appearance(group, params)
        else
          Letreiro.rebuild_backlight(model, group, faces, params, nil, preview: preview)
          group.set_attribute(ATTR_DICT, 'halo_radius_cm', params[:halo_radius_cm].to_f)
          group.set_attribute(ATTR_DICT, 'halo_falloff', params[:halo_falloff].to_f)
        end
        true
      else
        prep = ribbon_data(group, model)
        return false unless prep
        params[:smart_contour] = true if prep.delete(:smart_contour)
        group.transformation = Geom::Transformation.new
        Led.rebuild_ribbon(model, group, prep, params, nil, preview: preview)
        Led.store_ribbon_attrs(group, prep, params)
        true
      end
    rescue StandardError => error
      warn("K.Light aplicar configurações: #{error.full_message}")
      false
    end

    def self.paste_light_settings
      settings = @copied_light_settings
      unless settings
        UI.messagebox('K.Light: copie primeiro as configurações de uma luz de referência.')
        return
      end
      targets = klight_groups.select { |group| light_kind(group) == settings[:kind] }
      if targets.empty?
        UI.messagebox("K.Light: selecione uma ou mais luzes do tipo #{settings[:kind]}.")
        return
      end
      model = Sketchup.active_model
      model.start_operation('K.Light — Colar Configurações', true)
      changed = targets.count { |group| apply_settings_to_group(model, group, settings) }
      model.commit_operation
      model.active_view.invalidate
      UI.messagebox("K.Light: configurações aplicadas em #{changed} luz(es).")
    rescue StandardError => error
      model.abort_operation rescue nil
      UI.messagebox("K.Light: não foi possível colar as configurações.\n#{error.message}")
    end

    class << self
      alias_method :cmd_edit_single, :cmd_edit unless method_defined?(:cmd_edit_single)
    end

    def self.cmd_edit
      groups = klight_groups
      return cmd_edit_single if groups.length <= 1
      kinds = groups.map { |group| light_kind(group) }.uniq
      if kinds.length != 1
        UI.messagebox('K.Light: para edição em lote, selecione apenas luzes do mesmo tipo.')
        return
      end
      cmd_edit_batch(groups)
    end

    def self.batch_dialog_init(group, count)
      settings = settings_from_group(group)
      rgb = settings[:rgb_custom]
      common = { preset: settings[:preset].to_s, rgb: rgb ? '#%02x%02x%02x' % rgb : '#ff8800',
                 alpha_max: settings[:alpha_max].to_f, editing: true, batch_count: count }
      case settings[:kind]
      when 'spot'
        common.merge(tab: 'spot', angle_deg: settings[:angle_deg].to_f,
                     length_cm: settings[:length_cm].to_f, curve_exp: settings[:curve_exp].to_f)
      when 'backlight'
        common.merge(tab: 'backlight', halo_radius_cm: settings[:halo_radius_cm].to_f,
                     halo_falloff: settings[:halo_falloff].to_f, can_restyle: true)
      else
        common.merge(tab: 'faixa', width_cm: settings[:width_cm].to_f,
                     layers: settings[:layers].to_i, curve_exp: settings[:curve_exp].to_f,
                     offset_mm: settings[:offset_mm].to_f, direction: settings[:direction].to_s,
                     vertical: settings[:vertical].to_s)
      end
    end

    def self.cmd_edit_batch(groups)
      model = Sketchup.active_model
      init = batch_dialog_init(groups.first, groups.length)
      original = settings_from_group(groups.first)
      Dialog.show(
        ->(params) {
          groups.each { |group| apply_settings_to_group(model, group, params.merge(kind: original[:kind])) if group.valid? }
          model.commit_operation
          model.selection.clear
          groups.each { |group| model.selection.add(group) if group.valid? }
        },
        -> { model.abort_operation }, nil,
        ->(params) {
          # A inversão é aplicada uma única vez no commit. Em previews de
          # lote, reconstruções sucessivas não podem alternar o vetor salvo.
          preview_params = params.merge(kind: original[:kind], invert_direction: false)
          groups.each { |group| apply_settings_to_group(model, group, preview_params, preview: true) if group.valid? }
          model.active_view.invalidate
        },
        init: init,
        on_ready: -> { model.start_operation("K.Light — Editar #{groups.length} Luzes", true) }
      )
    end

    module Spot
      class SpotTargetTool
        def initialize(group)
          @group = group
          @ip = Sketchup::InputPoint.new
        end
        def activate
          Sketchup.status_text = 'K.Light Spot: clique no ponto para onde o facho deve apontar — ESC cancela'
        end
        def onMouseMove(_flags, x, y, view)
          @ip.pick(view, x, y)
          view.invalidate
        end
        def draw(view)
          return unless @ip.valid? && @group&.valid?
          data = KahDetalha::KLight.world_spot_data(@group)
          return unless data
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(202, 195, 7)
          view.draw(GL_LINES, [data.first, @ip.position])
          view.draw_points([@ip.position], 10, 1, Sketchup::Color.new(202, 195, 7)) rescue nil
        end
        def onLButtonUp(_flags, x, y, view)
          ip = Sketchup::InputPoint.new
          ip.pick(view, x, y)
          return unless ip.valid? && @group&.valid?
          model = view.model
          data = KahDetalha::KLight.world_spot_data(@group)
          return unless data
          apex = data.first
          target = ip.position
          normal = apex.vector_to(target)
          return if normal.length <= 1e-6
          normal.normalize!
          params = KahDetalha::KLight.settings_from_group(@group)
          model.start_operation('K.Light — Direcionar Spot', true)
          @group.transformation = Geom::Transformation.new
          Spot.rebuild_spot(model, @group, apex, normal, params, nil)
          KahDetalha::KLight.write_spot_attributes(@group, apex, normal, params, target)
          model.commit_operation
          model.selection.clear; model.selection.add(@group)
          model.select_tool(nil)
        rescue StandardError => error
          model.abort_operation rescue nil
          UI.messagebox("K.Light: não foi possível direcionar o spot.\n#{error.message}")
        end
        def onCancel(_reason, _view)
          Sketchup.active_model.select_tool(nil)
        end
      end

      def self.cmd_aim_selected_spot
        group = KLight.klight_groups.find { |item| KLight.light_kind(item) == 'spot' }
        unless group
          UI.messagebox('K.Light: selecione um Spot para definir o alvo.')
          return
        end
        Sketchup.active_model.select_tool(SpotTargetTool.new(group))
      end

      def self.face_world_data(face, transform)
        center = face.bounds.center.transform(transform)
        normal = face.normal.transform(transform)
        return nil if normal.length <= 1e-9
        normal.normalize!
        area = face.area(transform) rescue face.area
        [center, normal, area.to_f]
      end

      # Escolhe a face emissora de uma luminária agrupada sem explodir o
      # objeto. Faces mais horizontais têm prioridade; entre elas, escolhe a
      # face inferior e usa a maior área como desempate. A transformação
      # acumulada mantém a posição correta em grupos/componentes aninhados.
      def self.group_emitter_face_data(entity, parent_transform)
        transform = parent_transform * entity.transformation
        definition = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : entity
        entities = definition.entities
        candidates = []
        entities.grep(Sketchup::Face).each do |face|
          data = face_world_data(face, transform)
          candidates << data if data
        end
        entities.each do |child|
          next unless child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
          nested = group_emitter_face_data(child, transform)
          candidates << nested if nested
        end
        return nil if candidates.empty?
        horizontal = candidates.select { |_center, normal, _area| normal.z.abs >= 0.7 }
        pool = horizontal.empty? ? candidates : horizontal
        pool.min_by { |center, _normal, area| [center.z.to_f, -area] }
      end

      def self.selected_face_world_data(model)
        base = model.respond_to?(:edit_transform) ? model.edit_transform : Geom::Transformation.new
        model.selection.map do |entity|
          if entity.is_a?(Sketchup::Face)
            face_world_data(entity, base)
          elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            next if entity.is_a?(Sketchup::Group) && entity.get_attribute(ATTR_DICT, 'version')
            group_emitter_face_data(entity, base)
          end
        end.compact.map { |center, normal, _area| [center, normal] }
      end

      def self.create_replicated_spots(model, face_data, params)
        model.start_operation("K.Light — Replicar #{face_data.length} Spots", true)
        groups = face_data.map do |center, _face_normal|
          direction = Geom::Vector3d.new(0, 0, -1)
          direction.reverse! if params[:invert_direction]
          apex = center.offset(direction, -0.5 / 25.4)
          group = model.entities.add_group
          group.name = "K.Spot_#{params[:preset]}"
          group.layer = Core.ensure_tag(model)
          result = build_spot_geo(group.entities, apex, direction, params, model)
          raise 'Não foi possível gerar um dos spots.' if result[:created] == 0
          KLight.write_spot_attributes(group, apex, direction, params)
          group
        end
        model.commit_operation
        model.selection.clear
        groups.each { |group| model.selection.add(group) }
        model.active_view.invalidate
      rescue StandardError => error
        model.abort_operation rescue nil
        UI.messagebox("K.Light: não foi possível replicar os spots.\n#{error.message}")
      end

      def self.cmd_replicate_spots
        model = Sketchup.active_model
        face_data = selected_face_world_data(model)
        if face_data.empty?
          UI.messagebox('K.Light: selecione previamente duas ou mais faces de luminárias.')
          return
        end
        Dialog.show(
          ->(params) { create_replicated_spots(model, face_data, params) },
          nil, nil, nil,
          init: { tab: 'spot', replicate: true, replicate_count: face_data.length }
        )
      end


      def self.replicate_from_current_selection(params)
        model = Sketchup.active_model
        face_data = selected_face_world_data(model)
        if face_data.empty?
          UI.messagebox('K.Light: selecione faces, grupos ou componentes de luminárias antes de replicar.')
          return
        end
        create_replicated_spots(model, face_data, params)
      end
    end
  end
end
