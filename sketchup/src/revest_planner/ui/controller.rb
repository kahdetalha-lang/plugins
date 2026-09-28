# frozen_string_literal: true

require 'json'
require 'singleton'
require 'base64'
require 'tmpdir'
require 'fileutils'
# Ferramentas, escritores e exportador são carregados antes, pelo main.rb.

module RevestPlanner
  module UI
    class Controller
      include Singleton

      attr_reader :adapter, :result

      DEFAULTS = {
        'pattern' => 'aligned', 'width' => 60.0, 'height' => 60.0,
        'joint' => 0.2, 'thickness' => 9.0, 'dry_joint' => false, 'rotation' => 0.0, 'offset_u' => 0.0,
        'offset_v' => 0.0, 'stagger' => 0.5, 'waste_percent' => 10.0,
        'texture_paths' => [], 'texture_variation' => 1,
        'grout' => false, 'grout_color' => SketchupAdapter::GroutWriter::DEFAULT_COLOR
      }.freeze
      AUTO_CENTER_PATTERNS = %w[checkerboard diagonal brick chevron herringbone].freeze
      LICENSE_MESSAGE = 'A autorização do REVEST precisa ser renovada: abra a Central K-Plugins com internet.'

      def open
        # Sem autorização da Central K para este computador, o REVEST não abre.
        return unless RevestPlanner::License.authorized_or_explain

        restore_editing_group if @model
        @model = Sketchup.active_model
        @state = fresh_state
        @active_preset_name = nil
        @last_result = nil
        install_observers
        build_dialog unless @dialog
        @dialog.show
        selected = @model.selection.grep(Sketchup::Face)
        selected_layout = @model.selection.find { |entity| layout_group?(entity) }
        if selected_layout
          @selected_layout_group = selected_layout
          Sketchup.send_action('selectSelectionTool:')
          push_state
        else
          selected.length == 1 ? select_face(selected.first) : start_picker
        end
      end

      def fresh_state(extra = {})
        DEFAULTS.merge(extra).each_with_object({}) do |(key, value), memo|
          memo[key] = value.is_a?(Array) ? value.dup : value
        end
      end

      def select_face(face, path = nil)
        transformation = transformation_for(path)
        @adapter = SketchupAdapter::FaceAdapter.new(face, transformation)
        @anchor_point_world = nil
        if @state['pattern'] == 'quartzito' || @active_preset_name.to_s.empty?
          center_layout(false)
        end
        calculate
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      rescue StandardError => error
        ::UI.messagebox("Não foi possível usar essa face:\n#{display_error(error)}")
        start_picker
      end

      def close
        restore_editing_group
        @adapter = nil
        @result = nil
        @dialog.close if @dialog && @dialog.visible?
        Sketchup.send_action('selectSelectionTool:')
        @model.active_view.invalidate if @model
      end

      def anchor_mode?
        @anchor_mode == true
      end

      def rotation_mode?
        @rotation_mode == true
      end

      def start_anchor
        return push_error('Selecione uma face primeiro.') unless @adapter

        @rotation_mode = false
        @anchor_mode = true
        @model.select_tool(Tools::PreviewTool.new(self))
        Sketchup.set_status_text('Clique no ponto que será o início da paginação. Esc cancela.')
        push_state
      end

      def cancel_anchor
        @anchor_mode = false
        Sketchup.set_status_text('Ajuste a paginação no painel e clique em Gerar.')
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      end

      def start_rotation
        return push_error('Selecione uma face primeiro.') unless @adapter

        @anchor_mode = false
        @rotation_mode = true
        @rotation_original = @state['rotation'].to_f
        @rotation_original_offsets = [@state['offset_u'], @state['offset_v']]
        @rotation_anchor_world = anchor_point
        @model.select_tool(Tools::PreviewTool.new(self))
        Sketchup.set_status_text('Mova o mouse para rotacionar. Clique para confirmar; Esc cancela.')
        push_state
      end

      def update_rotation(world_point)
        return unless rotation_mode? && @rotation_anchor_world

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @last_rotation_update && now - @last_rotation_update < 0.04

        @last_rotation_update = now

        anchor_local = @adapter.frame.to_2d(@rotation_anchor_world)
        cursor_local = @adapter.frame.to_2d(world_point)
        vector = cursor_local - anchor_local
        return if vector.x.abs + vector.y.abs < 1.0e-6

        effective_degrees = Math.atan2(vector.y, vector.x) * 180.0 / Math::PI
        @state['rotation'] = normalize_degrees(effective_degrees - pattern_base_angle)
        unrotated = anchor_local.rotate(-layout_rotation_radians)
        @state['offset_u'] = unrotated.x * 25.4
        @state['offset_v'] = unrotated.y * 25.4
        calculate
        push_state
      end

      def finish_rotation
        @rotation_mode = false
        @rotation_anchor_world = nil
        Sketchup.set_status_text('Ajuste a paginação no painel e clique em Gerar.')
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      end

      def cancel_rotation
        @state['rotation'] = @rotation_original if @rotation_original
        if @rotation_original_offsets
          @state['offset_u'], @state['offset_v'] = @rotation_original_offsets
        end
        @rotation_mode = false
        @rotation_anchor_world = nil
        calculate if @adapter
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      end

      def set_anchor(world_point, mouse_ray = nil)
        local = @adapter.frame.to_2d(world_point)
        clicked = clicked_pattern_piece(local)
        nearest = clicked ? nearest_corner(clicked.source_polygon, local) : nearest_pattern_vertex(local)
        @anchor_direction = nil
        if nearest
          delta = local - nearest
          # O canto da peça clicada vai para o ponto clicado. A documentação marca a peça que fica
          # na direção canto -> centro dessa peça (e não canto -> clique: um clique em cima da
          # junta ou da borda deixava o lado ambíguo e marcava a peça vizinha).
          toward = clicked ? polygon_center(clicked.source_polygon) - nearest : delta
          # Clique que grudou num canto/aresta da parede: o ponto não está "dentro" de peça
          # nenhuma. Vale o lado em que o mouse estava, e só um lado que fique dentro do piso.
          snapped_side = snapped_click_side(local, mouse_ray)
          toward = snapped_side if snapped_side
          length = Math.hypot(toward.x, toward.y)
          @anchor_direction = [toward.x / length, toward.y / length] if length > 1.0e-6
          unrotated_delta = delta.rotate(-layout_rotation_radians)
          @state['offset_u'] = ((mm(@state['offset_u']) + unrotated_delta.x) * 25.4).round(2)
          @state['offset_v'] = ((mm(@state['offset_v']) + unrotated_delta.y) * 25.4).round(2)
        else
          unrotated = local.rotate(-layout_rotation_radians)
          @state['offset_u'] = (unrotated.x * 25.4).round(2)
          @state['offset_v'] = (unrotated.y * 25.4).round(2)
        end
        @anchor_point_world = world_point
        @anchor_mode = false
        calculate
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      end

      def anchor_point
        return nil unless @adapter
        return @anchor_point_world if @anchor_point_world

        local = Core::Point2d.new(mm(@state['offset_u']), mm(@state['offset_v']))
        @adapter.frame.to_3d(local.rotate(layout_rotation_radians), 0.8 / 25.4)
      end

      def anchor_axis_size
        [cm(@state['width']) * 0.22, cm(@state['height']) * 0.22, 1.0].max
      end

      def center_layout(refresh = true)
        return push_error('Selecione uma face primeiro.') unless @adapter

        @anchor_point_world = nil

        bounds = @adapter.clipping_regions.map(&:bounds)
        center = Core::Point2d.new(
          (bounds.map { |item| item[0] }.min + bounds.map { |item| item[2] }.max) / 2.0,
          (bounds.map { |item| item[1] }.min + bounds.map { |item| item[3] }.max) / 2.0
        )
        local_center = center.rotate(-layout_rotation_radians)
        reference = pattern_reference_center
        @state['offset_u'] = ((local_center.x - reference.x) * 25.4).round(2)
        @state['offset_v'] = ((local_center.y - reference.y) * 25.4).round(2)
        if refresh
          calculate
          push_state
        end
      end

      private

      def nearest_pattern_vertex(local_point)
        return nil unless @result

        whole_pieces = @result.pieces.select { |piece| piece.classification == :whole }
        candidates = whole_pieces.empty? ? @result.pieces : whole_pieces
        candidates.flat_map { |piece| piece.source_polygon.points }.min_by do |point|
          dx = point.x - local_point.x
          dy = point.y - local_point.y
          (dx * dx) + (dy * dy)
        end
      end

      # Peça do desenho em que se clicou (forma inteira, antes do recorte); clique na junta ou fora
      # de qualquer peça -> a de centro mais próximo.
      def clicked_pattern_piece(local_point)
        return nil unless @result && !@result.pieces.empty?

        @result.pieces.find { |piece| point_in_polygon?(local_point, piece.source_polygon.points) } ||
          @result.pieces.min_by { |piece| polygon_center(piece.source_polygon).distance(local_point) }
      end

      # Diagonal (±u ±v da grade) do lado em que o mouse estava, preferindo os lados que caem
      # dentro da face. nil quando o clique não grudou em nada (o mouse está no próprio ponto).
      def snapped_click_side(local, mouse_ray)
        return nil unless mouse_ray

        frame = @adapter.frame
        raw_world = Geom.intersect_line_plane(mouse_ray, [frame.origin, frame.normal])
        return nil unless raw_world

        raw = frame.to_2d(raw_world)
        mouse = raw - local
        return nil if Math.hypot(mouse.x, mouse.y) < 1.0e-3

        angle = layout_rotation_radians
        u = Core::Point2d.new(Math.cos(angle), Math.sin(angle))
        v = Core::Point2d.new(-Math.sin(angle), Math.cos(angle))
        step = [cm(@state['width']), cm(@state['height'])].select(&:positive?).min.to_f * 0.2
        step = 0.5 unless step.positive?
        sides = [[1, 1], [-1, 1], [-1, -1], [1, -1]].map { |su, sv| (u * su + v * sv) * Math.sqrt(0.5) }
        regions = @adapter.clipping_regions
        inside = sides.select do |side|
          probe = local + side * step
          regions.any? { |region| point_in_polygon?(probe, region.points) }
        end
        (inside.empty? ? sides : inside).max_by { |side| side.x * mouse.x + side.y * mouse.y }
      rescue StandardError
        nil
      end

      def nearest_corner(polygon, local_point)
        polygon.points.min_by { |point| point.distance(local_point) }
      end

      def polygon_center(polygon)
        points = polygon.points
        Core::Point2d.new(points.sum(&:x) / points.length, points.sum(&:y) / points.length)
      end

      def point_in_polygon?(point, points)
        inside = false
        previous = points.last
        points.each do |current|
          if (current.y > point.y) != (previous.y > point.y)
            crossing = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
            inside = !inside if point.x < crossing
          end
          previous = current
        end
        inside
      end

      def start_picker
        restore_editing_group
        @adapter = nil
        @result = nil
        @anchor_point_world = nil
        @model.select_tool(Tools::FacePickerTool.new(self))
        push_state
      end

      # Medidas inválidas ou peças demais não lançam erro: a prévia fica vazia e a mensagem aparece
      # na janela (push_state). Assim nenhum botão/ferramenta que recalcula fica com exceção solta.
      def calculate
        @result = layout_result_for(@adapter, @state)
        @calculation_error = nil
      rescue ArgumentError => error
        @result = nil
        @calculation_error = error.message
      ensure
        @model.active_view.invalidate
      end

      def layout_result_for(adapter, state)
        joint = state['dry_joint'] ? 0.0 : cm(state['joint'])
        tile = Core::TileSpec.new(
          width: cm(state['width']), height: cm(state['height']), joint: joint
        )
        layout = Core::LayoutSpec.new(
          pattern: state['pattern'], rotation: state['rotation'].to_f.degrees,
          offset_u: mm(state['offset_u']), offset_v: mm(state['offset_v']),
          stagger: state['stagger']
        )
        Core::LayoutEngine.new(tile_spec: tile, layout_spec: layout).call(adapter.clipping_regions)
      end

      def grout_possible?(state)
        !state['dry_joint'] && state['joint'].to_f.positive?
      end

      # Rejunte da paginação que está sendo editada/gerada: vale na hora de gerar.
      # Com uma paginação pronta selecionada, aplica direto nela (cria, recolore ou remove).
      def update_grout(json)
        values = JSON.parse(json)
        enabled = !!values['grout']
        color = SketchupAdapter::GroutWriter.normalize_color(values['grout_color'])
        group = @adapter ? nil : selected_layout_group
        warning = nil
        if group
          warning = apply_grout_to_group(group, enabled, color)
        else
          @state['grout'] = enabled
          @state['grout_color'] = color
          warning = 'O rejunte só aparece com junta maior que zero (desmarque Junta seca).' if enabled && !grout_possible?(@state)
        end
        push_state
        push_error(warning) if warning
      rescue StandardError => error
        puts "REVEST rejunte: #{error.class}: #{error.message}"
        puts Array(error.backtrace).first(5).join("\n")
        push_state
        push_error("Não foi possível aplicar o rejunte: #{display_error(error)}")
      end

      def apply_grout_to_group(group, enabled, color)
        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        state = DEFAULTS.merge(data['state'] || {})
        return 'Esta paginação tem junta seca: não há vão para o rejunte.' if enabled && !grout_possible?(state)

        @model.start_operation('Rejunte', true)
        if !enabled
          SketchupAdapter::GroutWriter.remove(group)
        elsif !SketchupAdapter::GroutWriter.recolor(@model, group, color)
          adapter, result = layout_source_for(data)
          SketchupAdapter::GroutWriter.new(
            model: @model, group: group, adapter: adapter, result: result,
            thickness: mm(state['thickness']), color: color,
            joint: cm(state['joint']), pattern: state['pattern']
          ).write
        end
        data['state'] = (data['state'] || {}).merge('grout' => enabled, 'grout_color' => color)
        group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
        @model.commit_operation
        @state['grout'] = enabled
        @state['grout_color'] = color
        nil
      rescue StandardError
        @model.abort_operation
        raise
      end

      # Reconstrói superfície e peças de uma paginação pronta a partir dos dados gravados nela.
      def layout_source_for(data)
        face = @model.find_entity_by_persistent_id(data['face_pid'].to_i)
        raise ArgumentError, 'a face original desta paginação não existe mais.' unless face.is_a?(Sketchup::Face) && face.valid?

        transformation = Geom::Transformation.new(Array(data['transformation']))
        adapter = if data['curved_surface']
                    SketchupAdapter::CurvedSurfaceAdapter.build(face, transformation)
                  else
                    SketchupAdapter::FaceAdapter.new(face, transformation)
                  end
        [adapter, layout_result_for(adapter, DEFAULTS.merge(data['state'] || {}))]
      end

      def grout_payload
        group = @adapter ? nil : selected_layout_group
        if group
          state = DEFAULTS.merge(JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))['state'] || {})
          grout = SketchupAdapter::GroutWriter.grout_group(group)
          return { enabled: !grout.nil?, color: grout ? grout.get_attribute('RevestPlanner', 'grout_color') || state['grout_color'] : state['grout_color'],
                   available: grout_possible?(state), target: 'group' }
        end
        { enabled: !!@state['grout'], color: SketchupAdapter::GroutWriter.normalize_color(@state['grout_color']),
          available: grout_possible?(@state), target: 'state' }
      rescue StandardError
        { enabled: !!@state['grout'], color: SketchupAdapter::GroutWriter.normalize_color(@state['grout_color']),
          available: grout_possible?(@state), target: 'state' }
      end

      def build_dialog
        @dialog = ::UI::HtmlDialog.new(
          dialog_title: 'REVEST', preferences_key: 'RevestPlanner',
          scrollable: true, resizable: true, width: 500, height: 780,
          min_width: 390, min_height: 560, style: ::UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_file(File.join(RevestPlanner::PLUGIN_ROOT, 'ui', 'web', 'index.html'))
        @dialog.add_action_callback('ready') { |_context| push_state }
        @dialog.add_action_callback('update') { |_context, json| update_state(json) }
        @dialog.add_action_callback('updateGrout') { |_context, json| update_grout(json) }
        @dialog.add_action_callback('pickFace') { |_context| start_picker }
        @dialog.add_action_callback('clearTextures') { |_context| clear_imported_textures }
        @dialog.add_action_callback('importTexture') { |_context, json| import_texture(json) }
        @dialog.add_action_callback('finishTextures') { |_context| push_state }
        @dialog.add_action_callback('varyCombination') { |_context| vary_combination }
        @dialog.add_action_callback('exportCsv') { |_context| export_csv }
        @dialog.add_action_callback('exportToLayout') { |_context, json| export_to_layout(json) }
        @dialog.add_action_callback('exportPng') { |_context, data| export_png(data) }
        @dialog.add_action_callback('requestReportTexture') { |_context, group_id| send_report_texture(group_id) }
        @dialog.add_action_callback('pickAnchor') { |_context| start_anchor }
        @dialog.add_action_callback('rotateInModel') { |_context| start_rotation }
        @dialog.add_action_callback('centerLayout') { |_context| center_layout }
        @dialog.add_action_callback('savePreset') { |_context, json| save_preset(json) }
        @dialog.add_action_callback('loadPreset') { |_context, id| load_preset(id) }
        @dialog.add_action_callback('deletePreset') { |_context, id| delete_preset(id) }
        @dialog.add_action_callback('openSelectedReport') { |_context| open_selected_report }
        @dialog.add_action_callback('editSelectedLayout') { |_context| edit_selected_layout }
        @dialog.add_action_callback('saveFinalReportState') { |_context, json| save_final_report_state(json) }
        @dialog.add_action_callback('requestDocumentation') { |_context| push_state }
        @dialog.add_action_callback('updateDocumentation') { |_context, json| update_documentation(json) }
        @dialog.add_action_callback('pickDocumentationPosition') { |_context, mode| pick_documentation_position(mode) }
        @dialog.add_action_callback('pickArrowOrigin') { |_context, group_id| pick_arrow_origin(group_id) }
        @dialog.add_action_callback('rotateArrows') { |_context, group_id, step| rotate_arrows(group_id, step) }
        @dialog.add_action_callback('flipArrows') { |_context, group_id, axis| flip_arrows(group_id, axis) }
        @dialog.add_action_callback('scaleTag') { |_context, group_id, factor| scale_tag(group_id, factor) }
        @dialog.add_action_callback('scaleArrows') { |_context, group_id, factor| scale_arrows(group_id, factor) }
        @dialog.add_action_callback('arrowToolKey') { |_context, name| @arrow_tool&.handle_key(name.to_s) }
        @dialog.add_action_callback('generate') { |_context| generate }
        @dialog.set_on_closed do
          restore_editing_group
          @dialog = nil
          @adapter = nil
          @result = nil
          Sketchup.send_action('selectSelectionTool:')
        end
      end

      def update_state(json)
        incoming = JSON.parse(json)
        pattern_changed = incoming['pattern'] && incoming['pattern'] != @state['pattern']
        @state.merge!(incoming)
        @state['rotation'] = (%w[brick chevron].include?(@state['pattern']) ? 90.0 : 0.0) if pattern_changed
        if pattern_changed && @adapter &&
           (@state['pattern'] == 'quartzito' || AUTO_CENTER_PATTERNS.include?(@state['pattern']))
          center_layout
          return
        end
        calculate if @adapter
        push_state
      rescue StandardError => error
        push_state
        push_error(display_error(error))
      end

      def clear_imported_textures
        @texture_import_directory = File.join(
          Dir.tmpdir, 'revest_planner_textures', "session_#{Time.now.to_i}_#{rand(10_000)}"
        )
        FileUtils.mkdir_p(@texture_import_directory)
        @state['texture_paths'] = []
        @state['texture_variation'] = 1
        true
      end

      def import_texture(json)
        data = JSON.parse(json)
        encoded = data['data'].to_s.split(',', 2).last
        raise ArgumentError, 'Imagem sem conteúdo.' if encoded.nil? || encoded.empty?

        extension = data['mime'] == 'image/png' ? '.png' : '.jpg'
        basename = File.basename(data['name'].to_s, '.*').gsub(/[^0-9A-Za-z_-]+/, '_')[0, 60]
        basename = 'textura' if basename.empty?
        index = @state['texture_paths'].length + 1
        path = File.join(@texture_import_directory, format('%03d_%s%s', index, basename, extension))
        File.binwrite(path, Base64.strict_decode64(encoded))
        @state['texture_paths'] << path
        true
      rescue StandardError => error
        puts "REVEST não importou a imagem: #{error.message}"
        false
      end

      def presets_directory
        base = ENV['LOCALAPPDATA'].to_s
        base = Dir.tmpdir if base.empty?
        File.join(base, 'RevestPlanner', 'presets')
      end

      def presets_file
        File.join(presets_directory, 'presets.json')
      end

      # Lidos do disco uma vez e mantidos em memória: push_state roda a cada mudança de seleção.
      def read_presets
        @presets_cache ||= begin
          if File.file?(presets_file)
            data = JSON.parse(File.binread(presets_file).force_encoding('UTF-8'))
            data.is_a?(Array) ? data : []
          else
            []
          end
        rescue StandardError => error
          puts "REVEST não leu os presets: #{error.message}"
          []
        end
        @presets_cache.map(&:dup)
      end

      def write_presets(presets)
        FileUtils.mkdir_p(presets_directory)
        temporary = "#{presets_file}.tmp"
        File.binwrite(temporary, JSON.pretty_generate(presets))
        FileUtils.mv(temporary, presets_file, force: true)
      ensure
        @presets_cache = nil
        @preset_payload_cache = nil
      end

      def save_preset(json)
        request = JSON.parse(json)
        name = request['name'].to_s.strip
        raise ArgumentError, 'Informe um nome para o preset.' if name.empty?
        @state.merge!(request['values']) if request['values'].is_a?(Hash)

        presets = read_presets
        id = request['id'].to_s
        id = "preset_#{Time.now.to_i}_#{rand(1_000_000)}" if id.empty?
        texture_paths = persist_preset_textures(id, Array(@state['texture_paths']))
        values = DEFAULTS.keys.each_with_object({}) { |key, memo| memo[key] = @state[key] unless key == 'texture_paths' }
        preset = { 'id' => id, 'name' => name, 'values' => values, 'texture_paths' => texture_paths, 'updated_at' => Time.now.to_i }
        index = presets.index { |item| item['id'] == id }
        index ? presets[index] = preset : presets << preset
        write_presets(presets)
        @active_preset_name = name
        push_state
        true
      rescue StandardError => error
        push_error("Não foi possível salvar o preset: #{display_error(error)}")
        false
      end

      # Presets copiados de outro computador guardam o caminho de lá (outro usuário do Windows):
      # procura a mesma textura dentro da pasta de presets deste computador.
      def preset_texture_path(path)
        return path if File.file?(path.to_s)

        relative = path.to_s.split(/[\\\/]presets[\\\/]/, 2)[1]
        return nil unless relative

        local = File.join(presets_directory, relative.tr('\\', '/'))
        File.file?(local) ? local : nil
      end

      def persist_preset_textures(id, source_paths)
        destination = File.join(presets_directory, id, 'textures')
        staging = File.join(Dir.tmpdir, "revest_preset_#{id}_#{rand(1_000_000)}")
        FileUtils.mkdir_p(staging)
        copied = []
        source_paths.each_with_index do |source, index|
          next unless File.file?(source)

          extension = File.extname(source).downcase
          extension = '.jpg' unless %w[.jpg .jpeg .png].include?(extension)
          staged = File.join(staging, format('%03d%s', index + 1, extension))
          FileUtils.cp(source, staged)
          copied << staged
        end
        FileUtils.rm_rf(destination) if File.directory?(destination)
        FileUtils.mkdir_p(destination)
        copied.map do |staged|
          final_path = File.join(destination, File.basename(staged))
          FileUtils.mv(staged, final_path)
          final_path
        end
      ensure
        FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      end

      def load_preset(id)
        preset = read_presets.find { |item| item['id'] == id.to_s }
        return push_error('Preset não encontrado.') unless preset

        @state.merge!(preset['values'] || {})
        @state['texture_paths'] = Array(preset['texture_paths']).map { |path| preset_texture_path(path) }.compact
        @active_preset_name = preset['name'].to_s
        @anchor_point_world = nil
        calculate if @adapter
        push_state
        true
      rescue StandardError => error
        push_error("Não foi possível carregar o preset: #{display_error(error)}")
        false
      end

      def delete_preset(id)
        presets = read_presets
        removed = presets.find { |item| item['id'] == id.to_s }
        return false unless removed

        presets.reject! { |item| item['id'] == id.to_s }
        write_presets(presets)
        directory = File.expand_path(File.join(presets_directory, removed['id'].to_s))
        root = File.expand_path(presets_directory)
        FileUtils.rm_rf(directory) if directory.start_with?(root + File::SEPARATOR)
        push_state
        true
      rescue StandardError => error
        push_error("Não foi possível excluir o preset: #{display_error(error)}")
        false
      end

      def generate
        return push_error(LICENSE_MESSAGE) unless RevestPlanner::License.authorized?
        return push_error('Selecione uma face primeiro.') unless @adapter
        return push_error(@calculation_error || 'A prévia ainda não foi calculada. Confira as medidas.') unless @result
        return push_error('A espessura da peça não pode ser negativa.') if @state['thickness'].to_f.negative?

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        materials = materials_from_textures(@editing_group)
        materials_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if !effective_texture_paths.empty? && materials.empty?
          return push_error('As imagens não puderam ser carregadas. Tente arquivos JPG ou PNG locais.')
        end
        final_report = final_report_payload
        metadata = layout_metadata(final_report)
        if @editing_group && @editing_group.valid?
          previous = JSON.parse(@editing_group.get_attribute('RevestPlanner', 'layout_data'))
          if previous['documentation']
            begin
              SketchupAdapter::DocumentationWriter.new(model: @model, group: @editing_group, metadata: previous)
                                                  .capture_manual_moves
            rescue StandardError => error
              puts "REVEST não leu a posição da tag/setas: #{error.message}"
            end
            documentation = previous['documentation']
            old_state = previous['state'] || {}
            start_moved = previous['anchor_point'] != metadata['anchor_point'] ||
                          %w[offset_u offset_v rotation pattern].any? { |key| old_state[key] != @state[key] }
            if start_moved
              # O início da paginação mudou: peça inicial e setas voltam a seguir o ponto novo.
              %w[start_piece_id start_piece_manual direction_point].each { |key| documentation.delete(key) }
            end
            metadata['documentation'] = documentation
          end
        end
        group = SketchupAdapter::LayoutWriter.new(
          model: @model, adapter: @adapter, result: @result, materials: materials,
          thickness: mm(@state['thickness']), metadata: metadata, replace_group: @editing_group,
          texture_variation: @state['texture_variation']
        ).write
        if @state['grout'] && grout_possible?(@state)
          begin
            @model.start_operation('Rejunte', true, false, true)
            SketchupAdapter::GroutWriter.new(
              model: @model, group: group, adapter: @adapter, result: @result,
              thickness: mm(@state['thickness']), color: @state['grout_color'],
              joint: cm(@state['joint']), pattern: @state['pattern']
            ).write
            @model.commit_operation
          rescue StandardError => error
            @model.abort_operation
            puts "REVEST não criou o rejunte: #{error.class}: #{error.message}"
            puts Array(error.backtrace).first(5).join("\n")
            grout_error = "A paginação foi gerada, mas o rejunte não: #{display_error(error)}"
          end
        end
        @model.start_operation('Gerar paginação', true, false, true)
        begin
          if metadata['documentation']
            begin
              SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: metadata).apply
            rescue StandardError => error
              puts "REVEST não redesenhou a documentação: #{error.class}: #{error.message}"
            end
          end
          if @state['texture_variation'].to_i == 4 && materials.length >= 2
            apply_material_combination(group, materials, 4, own_operation: false)
          end
          final_report[:group_id] = group.persistent_id
          metadata['report']['group_id'] = group.persistent_id
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(metadata))
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        geometry_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @editing_group = nil
        finish_generation
        @model.selection.clear
        @model.selection.add(group)
        # O quantitativo não abre mais sozinho: fica no botão QUANTITATIVO da aba Documentação.
        @dialog.execute_script("window.RevestPlanner.generationDone()")
        push_error(grout_error) if grout_error
        finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        puts format(
          'REVEST clique→resultado: imagens %.2fs | malha %.2fs | finalização %.2fs | total %.2fs | %d imagens',
          materials_at - started_at, geometry_at - materials_at,
          finished_at - geometry_at, finished_at - started_at, materials.length
        )
      rescue StandardError => error
        push_error("Não foi possível gerar a paginação. #{display_error(error)}")
      end

      # Materiais REVEST já usados por uma paginação, na ordem das imagens (o nome traz o índice).
      # Só servem se forem exatamente as mesmas imagens, na mesma ordem.
      def reusable_materials(group, paths)
        return [] unless group && group.valid? && !paths.empty?

        found = {}
        group.entities.grep(Sketchup::Face).each do |face|
          material = face.material
          next unless material && material.texture && !found.value?(material)

          match = material.name.to_s.match(/\AREVEST \S+ (\d+) /)
          found[match[1].to_i] ||= material if match
          break if found.length > paths.length
        end
        return [] unless found.length == paths.length && found.keys.sort == (1..paths.length).to_a

        materials = paths.each_with_index.map { |path, index| [found[index + 1], path] }
        same = materials.all? do |material, path|
          File.basename(material.texture.filename.to_s).casecmp?(File.basename(path)) ||
            material.name.to_s.end_with?(" #{File.basename(path, '.*')}")
        end
        same ? materials.map(&:first) : []
      rescue StandardError
        []
      end

      def size_materials(materials, paths)
        materials.each_with_index do |material, index|
          next unless material.texture

          if @state['pattern'] == 'quartzito' && File.basename(paths[index].to_s).downcase == 'pedra_moledo_default.png'
            material.texture.size = [cm(200.0), cm(126.0)]
          else
            material.texture.size = [cm(@state['width']), cm(@state['height'])]
          end
        end
        materials
      end

      def materials_from_textures(reuse_from = nil)
        paths = effective_texture_paths
        reused = reusable_materials(reuse_from, paths)
        return size_materials(reused, paths) unless reused.empty?

        materials = []
        # Materiais são exclusivos desta geração para que uma nova paginação
        # nunca substitua a textura usada por uma paginação já existente.
        batch = "#{Time.now.to_i}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i}_#{rand(1_000_000)}"
        effective_texture_paths.each_with_index do |path, index|
          next unless File.file?(path)

          begin
            name = "REVEST #{batch} #{index + 1} #{File.basename(path, '.*')}"
            material = @model.materials.add(name)
            material.texture = path
            if material.texture
              if @state['pattern'] == 'quartzito' && File.basename(path).downcase == 'pedra_moledo_default.png'
                material.texture.size = [cm(200.0), cm(126.0)]
              else
                material.texture.size = [cm(@state['width']), cm(@state['height'])]
              end
            end
            materials << material if material.texture
          rescue StandardError => error
            puts "REVEST ignorou #{path}: #{error.message}"
          end
        end
        push_error('Nenhuma das imagens selecionadas pôde ser carregada.') if materials.empty? && !effective_texture_paths.empty?
        materials
      end

      def effective_texture_paths
        selected = Array(@state['texture_paths']).select { |path| File.file?(path) }
        return selected unless selected.empty? && @state['pattern'] == 'quartzito'

        default_path = default_moledo_texture_path
        default_path ? [default_path] : []
      end

      def vary_combination
        group = selected_layout_group

        if group
          metadata = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
          saved_state = fresh_state(metadata['state'] || {})
          variation = (saved_state['texture_variation'].to_i % 4) + 1
          saved_state['texture_variation'] = variation
          paths = Array(saved_state['texture_paths']).select { |path| File.file?(path) }
          return push_error('Esta paginação precisa de pelo menos duas imagens.') if paths.length < 2

          @state = saved_state
          materials = materials_from_textures(group)
          apply_material_combination(group, materials, variation)
          metadata['state'] = saved_state
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(metadata))
        else
          variation = (@state['texture_variation'].to_i % 4) + 1
          @state['texture_variation'] = variation
        end
        push_state
        variation
      rescue StandardError => error
        push_error("Não foi possível variar a combinação: #{display_error(error)}")
      end

      def apply_material_combination(group, materials, variation, own_operation: true)
        return if materials.length < 2

        @model.start_operation('Variar combinação REVEST', true) if own_operation
        faces_by_piece = group.entities.grep(Sketchup::Face).group_by do |face|
          face.get_attribute('RevestPlanner', 'piece_id')
        end
        faces_by_piece.each do |piece_id, faces|
          next unless piece_id

          alternating_index = variation == 4 ? alternating_combination_index(piece_id) : nil
          scattered_index = variation <= 3 ? scattered_combination_index(piece_id, variation, materials.length) : nil
          material = if !alternating_index.nil?
                       materials[alternating_index]
                     elsif !scattered_index.nil?
                       materials[scattered_index]
                     else
                       materials[combination_hash(piece_id, variation) % materials.length]
                     end
          if variation == 4
            textured = faces.select { |face| face.material && face.material.texture }
            textured.each { |face| rotate_face_texture(face, material, 0) }
            next
          end

          textured = faces.select { |face| face.material && face.material.texture }
          top_face = textured.max_by(&:area)
          rotate_face_texture(top_face, material, combination_rotation(piece_id, variation, material)) if top_face
          faces.each do |face|
            next if face == top_face
            next unless face.material && face.material.texture

            face.material = material
            face.back_material = material
          end
        end
        @model.commit_operation if own_operation
        @model.active_view.invalidate
      rescue StandardError
        @model.abort_operation if own_operation
        raise
      end

      def combination_rotation(piece_id, variation, material = nil)
        return 0 if variation == 4

        turn = (combination_hash(piece_id, variation) >> 8) % 4
        texture = material && material.texture
        image_width = texture && texture.respond_to?(:image_width) ? texture.image_width.to_f : 0.0
        image_height = texture && texture.respond_to?(:image_height) ? texture.image_height.to_f : 0.0
        return turn unless image_width.positive? && image_height.positive?
        return turn if (image_width / image_height - 1.0).abs < 0.02

        turn.even? ? turn : (turn + 1) % 4
      end

      def alternating_combination_index(piece_id)
        id = piece_id.to_s
        if (match = id.match(/r(-?\d+)c(-?\d+)/))
          return (match[1].to_i + match[2].to_i).even? ? 0 : 1
        end
        if (match = id.match(/d(-?\d+)_(-?\d+)_(-?\d+)/))
          return (match[1].to_i + match[2].to_i + match[3].to_i).even? ? 0 : 1
        end

        nil
      end

      def scattered_combination_index(piece_id, variation, material_count)
        match = piece_id.to_s.match(/r(-?\d+)c(-?\d+)/)
        return nil unless match && material_count >= 2

        row = match[1].to_i
        column = match[2].to_i
        block_size = { 1 => 3, 2 => 2, 3 => 4 }.fetch(variation, 3)
        row_seed = stable_grid_hash(row, variation) % material_count
        (column + column.div(block_size) + row_seed) % material_count
      end

      def stable_grid_hash(value, variation)
        number = (value * 1_103_515_245) ^ (variation * 12_345)
        number ^= (number >> 16)
        number.abs
      end

      def rotate_face_texture(face, material, desired_turn)
        points = face.outer_loop.vertices.first(3).map(&:position)
        return if points.length < 3

        helper = face.get_UVHelper(true, true)
        current_uv = points.map do |point|
          uvq = helper.get_front_UVQ(point)
          q = uvq.z.to_f.abs < 1.0e-9 ? 1.0 : uvq.z.to_f
          [uvq.x.to_f / q, uvq.y.to_f / q]
        end
        current_turn = face.get_attribute('RevestPlanner', 'texture_quarter_turn', 0).to_i
        delta = (desired_turn - current_turn) % 4
        rotated_uv = current_uv.map { |coordinates| rotate_texture_uv(coordinates, delta) }
        face.material = material
        face.back_material = material
        mapping = []
        points.each_with_index do |point, index|
          mapping << point
          mapping << Geom::Point3d.new(rotated_uv[index][0], rotated_uv[index][1], 0)
        end
        face.position_material(material, mapping, true)
        face.set_attribute('RevestPlanner', 'texture_quarter_turn', desired_turn)
      rescue StandardError
        face.material = material if face
        face.back_material = material if face
      end

      def rotate_texture_uv(coordinates, quarter_turn)
        u, v = coordinates
        case quarter_turn % 4
        when 1 then [1.0 - v, u]
        when 2 then [1.0 - u, 1.0 - v]
        when 3 then [v, 1.0 - u]
        else [u, v]
        end
      end

      def combination_hash(piece_id, variation)
        hash = 2_166_136_261
        piece_id.to_s.each_byte do |byte|
          hash ^= byte
          hash = (hash * 16_777_619) & 0xffffffff
        end
        hash ^= (variation.to_i * 2_654_435_761) & 0xffffffff
        hash ^= (hash >> 13)
        hash = (hash * 1_274_126_177) & 0xffffffff
        hash ^ (hash >> 16)
      end

      def default_moledo_texture_path
        encoded_path = File.join(RevestPlanner::PLUGIN_ROOT, 'assets', 'pedra_moledo_default.png.b64')
        return nil unless File.file?(encoded_path)

        base = ENV['LOCALAPPDATA'].to_s
        base = Dir.tmpdir if base.empty?
        directory = File.join(base, 'RevestPlanner', 'assets')
        destination = File.join(directory, 'pedra_moledo_default.png')
        if !File.file?(destination) || File.mtime(destination) < File.mtime(encoded_path)
          FileUtils.mkdir_p(directory)
          File.binwrite(destination, Base64.strict_decode64(File.read(encoded_path).gsub(/\s+/, '')))
        end
        destination
      rescue StandardError => error
        puts "REVEST não preparou a textura padrão da Pedra orgânica: #{error.message}"
        nil
      end

      def finish_generation
        @anchor_mode = false
        @rotation_mode = false
        @rotation_anchor_world = nil
        @anchor_point_world = nil
        @last_result = @result
        @last_face_area_m2 = face_area_m2
        @adapter = nil
        @result = nil
        Sketchup.send_action('selectSelectionTool:')
        @model.active_view.invalidate
        push_state
      end

      def push_state
        return unless @dialog

        combination_state = @state
        group = selected_layout_group
        if group && !@adapter
          stored = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
          combination_state = DEFAULTS.merge(stored['state'] || {})
        end
        payload = {
          state: @state,
          presets: preset_payload,
          selected_layout: !selected_layout_group.nil?,
          can_vary_combination: !!((group || @adapter) && Array(combination_state['texture_paths']).count { |path| File.file?(path) } > 1),
          texture_variation: combination_state['texture_variation'].to_i.clamp(1, 4),
          editing_layout: !!(@editing_group && @editing_group.valid?),
          anchor_mode: anchor_mode?,
          rotation_mode: rotation_mode?,
          face: @adapter ? { selected: true, area_m2: face_area_m2 } : { selected: false },
          result: result_payload,
          documentation: documentation_payload(group),
          grout: grout_payload
        }
        @dialog.execute_script("window.RevestPlanner.receive(#{JSON.generate(payload)})")
        push_error(@calculation_error) if @adapter && @calculation_error
      end

      def preset_payload
        @preset_payload_cache ||= read_presets.sort_by { |item| -item['updated_at'].to_i }.map do |item|
          values = item['values'] || {}
          {
            id: item['id'], name: item['name'], pattern: values['pattern'],
            width: values['width'], height: values['height'], thickness: values['thickness'],
            joint: values['joint'], dry_joint: values['dry_joint'],
            waste_percent: values['waste_percent'],
            texture_count: Array(item['texture_paths']).count { |path| preset_texture_path(path) }
          }
        end
      end

      # Vários eventos de seleção seguidos (clique, arrastar, Ctrl+A) viram uma única atualização.
      def schedule_selection_refresh
        return unless @dialog
        return if @selection_refresh_pending

        @selection_refresh_pending = true
        ::UI.start_timer(0.12, false) do
          @selection_refresh_pending = false
          selection_changed
        end
      end

      def result_payload
        # Com uma face em edição, mostra só o cálculo dela (vazio se as medidas foram recusadas).
        report = @adapter ? @result : @last_result
        return nil unless report

        waste = [[@state['waste_percent'].to_f, 0.0].max, 100.0].min
        installed = report.whole_count + report.cut_count
        purchase_pieces = (installed * (1.0 + waste / 100.0)).ceil
        selected_area = @adapter ? raw_face_area_m2 : @last_face_area_m2.to_f

        {
          whole_count: report.whole_count, cut_count: report.cut_count,
          irregular_cut_count: report.irregular_cut_count,
          installed_count: installed, waste_percent: waste,
          waste_pieces: purchase_pieces - installed,
          purchase_pieces: purchase_pieces,
          area_total_m2: selected_area.round(2)
        }
      end

      def final_report_payload
        {
          name: @active_preset_name.to_s.empty? ? 'Revestimento' : @active_preset_name,
          pattern: @state['pattern'], width: @state['width'].to_f, height: @state['height'].to_f,
          thickness: @state['thickness'].to_f, joint: @state['dry_joint'] ? 0.0 : @state['joint'].to_f,
          dry_joint: @state['dry_joint'], rotation: @state['rotation'].to_f,
          waste_percent: @state['waste_percent'].to_f, area_m2: raw_face_area_m2,
          whole_count: @result.whole_count, cut_count: @result.cut_count,
          total_count: @result.whole_count + @result.cut_count,
          piece_area_m2: (@state['width'].to_f * @state['height'].to_f / 10_000.0)
        }
      end

      def layout_metadata(report)
        {
          'version' => 1,
          'state' => @state.each_with_object({}) { |(key, value), memo| memo[key] = value },
          'report' => JSON.parse(JSON.generate(report)),
          'face_pid' => @adapter.face.persistent_id,
          'anchor_point' => @anchor_point_world ? @anchor_point_world.to_a : nil,
          'anchor_direction' => @anchor_point_world ? @anchor_direction : nil,
          'curved_surface' => @adapter.respond_to?(:curved?) && @adapter.curved?,
          'transformation' => @adapter.transformation.to_a
        }
      end

      def selected_layout_group
        return @selected_layout_group if @selected_layout_group && @selected_layout_group.valid?
        return nil unless @model

        @model.selection.find { |entity| layout_group?(entity) }
      end

      def documentation_payload(group)
        return nil unless group

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        report = data['report'] || {}
        options = data['documentation'] || {}
        {
          group_id: group.persistent_id,
          report: report,
          indications: { start: !!options['start'], direction: !!options['direction'], tag: !!options['tag'] },
          arrow_count: [[options.fetch('arrow_count', 2).to_i, 1].max, 3].min,
          label: options['label'].to_s.empty? ? report['name'].to_s : options['label']
        }
      rescue StandardError => error
        puts "REVEST não leu a documentação: #{error.message}"
        nil
      end

      def update_documentation(json)
        request = JSON.parse(json)
        group = @model.find_entity_by_persistent_id(request['group_id'].to_i)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        chosen = request['indications'] || {}
        previous = data['documentation'] || {}
        options = previous.merge(
          'start' => chosen['start'] == true,
          'direction' => chosen['direction'] == true,
          'tag' => chosen['tag'] == true,
          'arrow_count' => [[request.fetch('arrow_count', previous.fetch('arrow_count', 2)).to_i, 1].max, 3].min,
          'label' => request['label'].to_s.strip
        )
        data['documentation'] = options
        changed = SketchupAdapter::DocumentationWriter::KEYS.select { |key| previous[key] != options[key] }
        changed << 'tag' if previous['label'] != options['label'] && options['tag']
        changed << 'direction' if previous['arrow_count'].to_i != options['arrow_count'] && options['direction']
        @model.start_operation('Atualizar documentação REVEST', true)
        begin
          SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(changed.uniq) unless changed.empty?
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        @model.active_view.invalidate
        push_state
        true
      rescue StandardError => error
        push_error("Não foi possível atualizar a documentação: #{display_error(error)}")
        false
      end

      def pick_documentation_position(mode)
        return push_error('Escolha uma indicação para posicionar.') unless %w[start tag].include?(mode)

        group = selected_layout_group
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless group

        @model.select_tool(Tools::DocumentationPlacementTool.new(self, group, mode))
        true
      rescue StandardError => error
        push_error("Não foi possível iniciar o posicionamento: #{display_error(error)}")
        false
      end

      def cancel_documentation_pick
        Sketchup.send_action('selectSelectionTool:')
        Sketchup.set_status_text('Selecione uma indicação na aba Documentação.')
        push_state
      end

      def documentation_prompt(message)
        return unless @dialog

        @dialog.execute_script("window.RevestPlanner.documentationPrompt(#{JSON.generate(message)})")
      end

      def finish_documentation_pick(group, mode, world_point, detail)
        return false unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        original = @model.find_entity_by_persistent_id(data['face_pid'].to_i)
        raise ArgumentError, 'A face original desta paginação não existe mais.' unless original.is_a?(Sketchup::Face) && original.valid?

        frame = SketchupAdapter::PlaneFrame.from_face(original, Geom::Transformation.new(Array(data['transformation'])))
        local = frame.to_2d(world_point)
        key = case mode
              when 'start'
                options['start_piece_id'] = detail.get_attribute('RevestPlanner', 'piece_id')
                options['start_piece_manual'] = true
                options.delete('direction_point')
                'start'
              else
                options['tag_point'] = [local.x, local.y]
                options.delete('tag_corner')
                'tag'
              end
        options[key] = true
        data['documentation'] = options
        @model.start_operation('Posicionar indicação REVEST', true)
        begin
          keys = mode == 'start' && options['direction'] ? %w[start direction] : [key]
          SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(keys)
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        Sketchup.send_action('selectSelectionTool:')
        @model.active_view.invalidate
        push_state
        true
      rescue StandardError => error
        push_error("Não foi possível posicionar a indicação: #{display_error(error)}")
        false
      end

      def arrow_group_from(group_id)
        group = @model.find_entity_by_persistent_id(group_id.to_i) if group_id.to_i.positive?
        layout_group?(group) ? group : selected_layout_group
      end

      # Abre a ferramenta única das setas (seguir o mouse, girar/quantidade/tamanho pelo teclado).
      def pick_arrow_origin(group_id)
        group = arrow_group_from(group_id)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        @model.select_tool(Tools::ArrowPlacementTool.new(self, group))
        true
      end

      # A ferramenta das setas avisa quando começa/termina, para o painel poder repassar as teclas
      # (o foco do teclado costuma ficar no painel depois de clicar em "Posicionar setas").
      def arrow_tool_started(tool)
        @arrow_tool = tool
        @dialog&.execute_script('window.RevestPlanner.arrowToolActive(true)')
      end

      def arrow_tool_finished(tool)
        return unless @arrow_tool.equal?(tool)

        @arrow_tool = nil
        @dialog&.execute_script('window.RevestPlanner.arrowToolActive(false)')
      end

      # Gira as setas sem sair do painel: -90 = Girar 90° (horário), 180 = Inverter.
      # Com 1 ou 2 setas no canto, a união fica no mesmo lugar e só o sentido muda.
      def rotate_arrows(group_id, step = -90)
        group = arrow_group_from(group_id)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        rotation = SketchupAdapter::DocumentationWriter.arrow_rotation(options)
        step = step.to_i.zero? ? -90 : step.to_i
        save_arrows(group, data, rotation: (rotation + step) % 360)
      rescue StandardError => error
        push_error("Não foi possível girar as setas: #{display_error(error)}")
        false
      end

      # Espelhar ↔ (axis 'h'): vira só as setas horizontais. Espelhar ↕ (axis 'v'): só as verticais.
      # O resultado é sempre um dos 4 giros possíveis do conjunto; procura qual deles bate.
      def flip_arrows(group_id, axis)
        group = arrow_group_from(group_id)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        writer = SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data)
        base = writer.arrow_base_angle
        count = SketchupAdapter::DocumentationWriter.arrow_count(options)
        rotation = SketchupAdapter::DocumentationWriter.arrow_rotation(options)
        flip_axis = axis.to_s == 'v' ? writer.horizontal_grid_angle + 90.0 : writer.horizontal_grid_angle
        normalize = lambda do |angle|
          value = (angle % 360.0).round(2)
          value >= 359.99 ? 0.0 : value
        end
        directions = lambda do |rot|
          main = base + rot
          list = [main]
          list << main - 90.0 if count >= 2
          list << main + 90.0 if count == 3
          list.map { |angle| normalize.call(angle) }.sort
        end
        flipped = directions.call(rotation).map do |angle|
          offset = (angle - flip_axis) % 180.0
          parallel = offset < 0.01 || offset > 179.99
          parallel ? normalize.call(angle + 180.0) : angle
        end.sort
        new_rotation = [0, 90, 180, 270].find { |candidate| directions.call(candidate) == flipped }
        return true if new_rotation.nil? || new_rotation == rotation # nada a espelhar nesse eixo

        save_arrows(group, data, rotation: new_rotation)
      rescue StandardError => error
        push_error("Não foi possível espelhar as setas: #{display_error(error)}")
        false
      end

      # Seta− / Seta+ do painel: muda o tamanho das setas (0,25× a 4×), mantendo posição e sentido.
      def scale_arrows(group_id, factor)
        group = arrow_group_from(group_id)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        current = SketchupAdapter::DocumentationWriter.arrow_scale(options)
        save_arrows(group, data, scale: (current * factor.to_f).clamp(0.25, 4.0).round(3))
      rescue StandardError => error
        push_error("Não foi possível mudar o tamanho das setas: #{display_error(error)}")
        false
      end

      # A− / A+ do painel: muda o tamanho da tag (0,4× a 3×).
      def scale_tag(group_id, factor)
        group = arrow_group_from(group_id)
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        options = data['documentation'] || {}
        current = options['tag_scale'].to_f.positive? ? options['tag_scale'].to_f : 1.0
        options['tag_scale'] = (current * factor.to_f).clamp(0.4, 3.0).round(3)
        options['tag'] = true
        data['documentation'] = options
        @model.start_operation('Tamanho da tag REVEST', true)
        begin
          SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(['tag'])
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        @model.active_view.invalidate
        true
      rescue StandardError => error
        push_error("Não foi possível mudar o tamanho da tag: #{display_error(error)}")
        false
      end

      # Chamado pela ferramenta das setas no clique. `point` em coordenadas 2D da paginação.
      def place_arrows(group, point:, rotation:, count:, scale:)
        return false unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        save_arrows(group, data, point: [point[0].to_f, point[1].to_f], rotation: rotation, count: count, scale: scale)
        Sketchup.send_action('selectSelectionTool:')
        true
      rescue StandardError => error
        ::UI.messagebox("REVEST: não foi possível posicionar as setas.\n#{display_error(error)}")
        false
      end

      def save_arrows(group, data, point: nil, rotation: nil, count: nil, scale: nil)
        options = data['documentation'] || {}
        options['direction'] = true
        options['direction_point'] = point if point
        options['direction_rotation'] = rotation.to_i % 360 unless rotation.nil?
        options['arrow_count'] = [[count.to_i, 1].max, 3].min if count
        options['direction_scale'] = scale.to_f if scale
        options.delete('direction_inverted')
        options.delete('direction_mirrored')
        data['documentation'] = options
        @model.start_operation('Setas REVEST', true)
        begin
          SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(['direction'])
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        @model.active_view.invalidate
        push_state
        true
      end


      def layout_group?(entity)
        entity && entity.valid? && entity.get_attribute('RevestPlanner', 'layout_data')
      rescue StandardError
        false
      end

      def selection_changed
        return unless @dialog && @model && @model.valid?

        # Dentro do grupo da paginação (ex.: ajustando as setas), continua mostrando a documentação dela.
        # Só olha seleções pequenas: com milhares de entidades selecionadas não há paginação a documentar.
        selection = @model.selection
        @selected_layout_group = (selection.length <= 50 ? selection.find { |entity| layout_group?(entity) } : nil) ||
                                 Array(@model.active_path).reverse.find { |entity| layout_group?(entity) }
        push_state
      rescue StandardError => error
        puts "REVEST: seleção não atualizada (#{error.message})"
      end

      # Salvar com uma paginação em edição gravaria o grupo oculto: ele reaparece durante o salvamento.
      def before_model_save
        @hidden_for_save = @editing_group if @editing_group && @editing_group.valid? && @editing_group.hidden?
        @hidden_for_save.hidden = false if @hidden_for_save
      rescue StandardError
        @hidden_for_save = nil
      end

      def after_model_save
        @hidden_for_save.hidden = true if @hidden_for_save && @hidden_for_save.valid? && @editing_group == @hidden_for_save
      rescue StandardError
        nil
      ensure
        @hidden_for_save = nil
      end

      def open_selected_report
        group = selected_layout_group
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless group

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        report = data['report'] || {}
        report['group_id'] = group.persistent_id
        # Cenas do arquivo, para marcar quais vão junto para o LayOut.
        report['scenes'] = @model.pages.map(&:name)
        @dialog.execute_script("window.RevestPlanner.openFinalReport(#{JSON.generate(report)})")
        true
      rescue StandardError => error
        push_error("Não foi possível abrir o relatório: #{display_error(error)}")
      end

      def edit_selected_layout
        group = selected_layout_group
        return push_error('Selecione uma paginação gerada pelo REVEST.') unless group

        edit_generated_layout(group)
      end

      def save_final_report_state(json)
        report = JSON.parse(json)
        group = @model.find_entity_by_persistent_id(report['group_id'].to_i)
        return false unless layout_group?(group)

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        stored = data['report'] || {}
        name_changed = stored['name'].to_s != report['name'].to_s
        return true if !name_changed && stored['waste_percent'].to_f == report['waste_percent'].to_f &&
                       stored['pieces_per_box'].to_i == report['pieces_per_box'].to_i

        stored['name'] = report['name'].to_s
        stored['waste_percent'] = report['waste_percent'].to_f
        stored['pieces_per_box'] = report['pieces_per_box'].to_i
        data['report'] = stored
        group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
        options = data['documentation'] || {}
        if name_changed && options['tag'] && options['label'].to_s.strip.empty?
          @model.start_operation('Atualizar tag REVEST', true)
          begin
            SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(['tag'])
            @model.commit_operation
          rescue StandardError
            @model.abort_operation
            raise
          end
        end
        true
      rescue StandardError => error
        puts "REVEST não atualizou o relatório: #{error.message}"
        false
      end

      def edit_generated_layout(group)
        return unless layout_group?(group)
        return if @editing_group == group && @adapter

        data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        face = @model.find_entity_by_persistent_id(data['face_pid'].to_i)
        return push_error('A face original desta paginação não existe mais.') unless face.is_a?(Sketchup::Face) && face.valid?

        10.times do
          break unless @model.active_path && @model.active_path.include?(group)
          break unless @model.close_active
        end
        @state = fresh_state(data['state'] || {})
        # Restaura o ponto de início escolhido (e o lado do canto), para a peça inicial continuar certa.
        stored_anchor = data['anchor_point']
        @anchor_point_world = stored_anchor.is_a?(Array) && stored_anchor.length == 3 ? Geom::Point3d.new(stored_anchor) : nil
        @anchor_direction = data['anchor_direction']
        transformation = Geom::Transformation.new(Array(data['transformation']))
        @adapter = if data['curved_surface']
                     SketchupAdapter::CurvedSurfaceAdapter.build(face, transformation)
                   else
                     SketchupAdapter::FaceAdapter.new(face, transformation)
                   end
        @editing_group = group
        group.hidden = true
        @selected_layout_group = group
        @active_preset_name = (data['report'] || {})['name']
        calculate
        build_dialog unless @dialog
        @dialog.show
        @model.select_tool(Tools::PreviewTool.new(self))
        push_state
      rescue StandardError => error
        push_error("Não foi possível editar esta paginação: #{display_error(error)}")
      end

      def restore_editing_group
        @editing_group.hidden = false if @editing_group && @editing_group.valid?
        @editing_group = nil
        @model.active_view.invalidate if @model
      rescue StandardError
        @editing_group = nil
      end

      def install_observers
        return if @observed_model == @model && @selection_observer

        begin
          @observed_model.selection.remove_observer(@selection_observer) if @observed_model && @selection_observer
          @observed_model.remove_observer(@model_observer) if @observed_model && @model_observer
        rescue StandardError
          nil
        end
        @selection_observer = LayoutSelectionObserver.new(self)
        @model.selection.add_observer(@selection_observer)
        @model_observer = LayoutModelObserver.new(self)
        @model.add_observer(@model_observer)
        @observed_model = @model
      end

      def export_to_layout(json)
        return false if @layout_export # um segundo clique durante a exportação é ignorado
        return finish_layout_export(LICENSE_MESSAGE) unless RevestPlanner::License.authorized?

        data = JSON.parse(json)
        group = @model.find_entity_by_persistent_id(data['group_id'].to_i)
        return push_error('Selecione uma paginação válida antes de exportar.') unless layout_group?(group)

        scenes = Array(data['scenes']).map(&:to_s) & @model.pages.map(&:name)
        include_quantitative = data['include_quantitative'] != false
        if !include_quantitative && scenes.empty?
          return finish_layout_export('Marque o Quantitativo ou pelo menos uma cena para exportar.')
        end
        return false if scenes.any? && !model_ready_for_layout_scenes?(scenes)

        filename = data['name'].to_s.gsub(/[^0-9A-Za-zÀ-ÿ _-]+/, '').strip
        filename = 'quantitativo_revestimento' if filename.empty?
        path = ::UI.savepanel('Exportar quantitativo para LayOut', nil, "#{filename}.layout")
        return false unless path
        path += '.layout' unless File.extname(path).downcase == '.layout'

        @layout_export = { data: data, group: group, scenes: scenes, path: path, step: 0,
                           include_quantitative: include_quantitative }
        layout_progress('Preparando a exportação…')
        next_layout_step
        true
      rescue StandardError => error
        finish_layout_export("Não foi possível criar o arquivo LayOut: #{display_error(error)}")
        false
      end

      # Cada etapa roda num timer: entre uma e outra o SketchUp redesenha a janela e o aviso de
      # progresso aparece (o Ruby bloqueia a interface enquanto trabalha).
      def next_layout_step
        ::UI.start_timer(0.15, false) { run_layout_step }
      end

      def run_layout_step
        job = @layout_export
        return unless job

        scenes = job[:scenes]
        case job[:step]
        when 0
          if scenes.any?
            refresh_tags_for_layout
            # O viewport do LayOut lê o .skp salvo e a tag vetorial usa o modelo aberto: os dois
            # precisam ser o mesmo estado, senão a tag vetorial não cobre a do SketchUp.
            @model.save if @model.modified?
          end
          layout_progress(job[:include_quantitative] ? 'Montando a página do quantitativo…' : 'Preparando o documento…')
        when 1
          group = job[:group]
          raise ArgumentError, 'A paginação foi apagada durante a exportação.' unless layout_group?(group)

          metadata = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
          texture = Array((metadata['state'] || {})['texture_paths']).find { |item| File.file?(item) }
          texture ||= texture_from_group(group)
          job[:exporter] = SketchupAdapter::LayoutExporter.new(
            data: job[:data], texture_path: texture, model_path: scenes.any? ? @model.path : nil, scenes: scenes,
            include_quantitative: job[:include_quantitative]
          ).start
          layout_progress(scenes.any? ? "Cena 1 de #{scenes.length}: #{scenes.first}…" : 'Salvando o arquivo…')
        else
          index = job[:step] - 2
          if index < scenes.length
            job[:exporter].add_scene(scenes[index])
            following = scenes[index + 1]
            layout_progress(following ? "Cena #{index + 2} de #{scenes.length}: #{following}…" : 'Salvando o arquivo…')
          else
            job[:exporter].save(job[:path])
            group = job[:group]
            if layout_group?(group)
              metadata = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
              (metadata['report'] ||= {})['layout_path'] = job[:path]
              group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(metadata))
            end
            return finish_layout_export(nil, job[:path])
          end
        end
        job[:step] += 1
        next_layout_step
      rescue StandardError => error
        finish_layout_export("Não foi possível criar o arquivo LayOut: #{display_error(error)}")
      end

      def layout_progress(message)
        Sketchup.set_status_text("REVEST: #{message}")
        @dialog&.execute_script("window.RevestPlanner.busy(#{JSON.generate(message)})")
      end

      def finish_layout_export(error_message, path = nil)
        @layout_export = nil
        Sketchup.set_status_text('')
        return unless @dialog

        @dialog.execute_script('window.RevestPlanner.busy(null)')
        # Aviso flutuante: o quantitativo fica aberto por cima do painel e esconderia a mensagem comum.
        message = error_message || "Arquivo LayOut salvo: #{File.basename(path)}"
        @dialog.execute_script("window.RevestPlanner.notice(#{JSON.generate(message)}, #{JSON.generate(error_message ? 'error' : 'ok')})")
      end

      # O LayOut lê as cenas do arquivo .skp salvo — então o modelo precisa estar salvo e atualizado.
      # O LayOut lê as cenas do .skp salvo (a última versão salva). Só é preciso que o arquivo exista;
      # eixos e demais ajustes das cenas ficam por conta de quem modela — sem perguntas na exportação.
      def model_ready_for_layout_scenes?(_scene_names)
        return true unless @model.path.to_s.empty?

        ::UI.messagebox('Para exportar cenas para o LayOut, salve o arquivo do SketchUp primeiro (Arquivo > Salvar).')
        false
      end

      # Redesenha as tags (no mesmo lugar) antes de exportar, para o "projeto" gravado nelas — usado
      # para desenhar a tag em vetor no LayOut — estar sempre atualizado com a versão do plugin.
      # Só as tags de versões antigas (sem o projeto vetorial gravado) são redesenhadas. Redesenhar
      # todas marcava o modelo como alterado e obrigava a salvar o .skp inteiro a cada exportação.
      def refresh_tags_for_layout
        @model.entities.grep(Sketchup::Group).each do |group|
          next unless layout_group?(group)

          tag = SketchupAdapter::DocumentationWriter.documentation_child(group, 'tag')
          next unless tag
          next if tag.entities.grep(Sketchup::Group).any? { |item| item.get_attribute('RevestPlanner', 'tag_layout') }

          data = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
          @model.start_operation('Atualizar tag REVEST', true)
          SketchupAdapter::DocumentationWriter.new(model: @model, group: group, metadata: data).apply(['tag'])
          group.set_attribute('RevestPlanner', 'layout_data', JSON.generate(data))
          @model.commit_operation
        rescue StandardError => error
          @model.abort_operation
          puts "REVEST não atualizou a tag antes de exportar: #{error.message}"
        end
      end

      def texture_from_group(group)
        face = group.entities.grep(Sketchup::Face).find { |item| item.material && item.material.texture }
        return nil unless face

        path = face.material.texture.filename
        File.file?(path) ? path : nil
      rescue StandardError
        nil
      end

      def export_csv
        report = result_payload
        return push_error('Ainda não existe um relatório para exportar.') unless report

        path = ::UI.savepanel('Salvar relatório CSV', nil, 'REVEST_quantitativo.csv')
        return unless path
        path += '.csv' unless File.extname(path).downcase == '.csv'
        rows = report_rows(report)
        content = rows.map { |row| row.map { |value| csv_value(value) }.join(';') }.join("\r\n")
        File.binwrite(path, "\xEF\xBB\xBF" + content.encode('UTF-8'))
      rescue StandardError => error
        push_error("Não foi possível salvar o CSV: #{display_error(error)}")
      end

      def export_png(data_url)
        path = ::UI.savepanel('Salvar relatório PNG', nil, 'REVEST_quantitativo.png')
        return unless path
        path += '.png' unless File.extname(path).downcase == '.png'
        encoded = data_url.to_s.split(',', 2).last
        File.binwrite(path, Base64.strict_decode64(encoded))
      rescue StandardError => error
        push_error("Não foi possível salvar o PNG: #{display_error(error)}")
      end

      def report_texture_data_url(group_id)
        group = @model.find_entity_by_persistent_id(group_id.to_i)
        return '' unless layout_group?(group)

        metadata = JSON.parse(group.get_attribute('RevestPlanner', 'layout_data'))
        path = Array((metadata['state'] || {})['texture_paths']).find { |item| File.file?(item) }
        path ||= texture_from_group(group)
        return '' unless path && File.file?(path)

        mime = File.extname(path).downcase == '.png' ? 'image/png' : 'image/jpeg'
        "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
      rescue StandardError
        ''
      end

      def send_report_texture(group_id)
        data_url = report_texture_data_url(group_id)
        @dialog.execute_script("window.RevestPlanner.exportPngWithTexture(#{JSON.generate(data_url)})") if @dialog
        true
      rescue StandardError => error
        push_error("Não foi possível carregar a textura para o PNG: #{display_error(error)}")
        @dialog.execute_script("window.RevestPlanner.exportPngWithTexture('')") if @dialog
        false
      end

      def report_rows(report)
        [
          ['REVEST - Relatório quantitativo', ''],
          ['Padrão', @state['pattern'] == 'quartzito' ? 'Pedra orgânica' : (@state['pattern'] == 'brick' ? 'Tijolinho' : @state['pattern'])],
          [@state['pattern'] == 'quartzito' ? 'Largura do módulo (cm)' : 'Largura da peça (cm)', @state['width']],
          [@state['pattern'] == 'quartzito' ? 'Altura do módulo (cm)' : 'Altura da peça (cm)', @state['height']],
          ['Espessura da peça (mm)', format_report_decimal(@state['thickness'])],
          ['Junta seca', @state['dry_joint'] ? 'Sim' : 'Não'],
          ['Junta efetiva (mm)', @state['dry_joint'] ? 0 : format_report_decimal(@state['joint'].to_f * 10.0)],
          ['Sugestão de compra (peças)', report[:purchase_pieces]],
          ['Quantidade de peças inteiras', report[:whole_count]],
          ['Quantidade de peças recortadas', report[:cut_count]],
          ['Quantidade total de peças', report[:installed_count]],
          ['Área total selecionada (m²)', format_report_decimal(report[:area_total_m2])],
          ['Percentual de perda (%)', format_report_decimal(report[:waste_percent])]
        ]
      end

      def csv_value(value)
        text = value.to_s.gsub('.', ',').gsub('"', '""')
        "\"#{text}\""
      end

      def format_report_decimal(value)
        format('%.2f', value.to_f).tr('.', ',')
      end

      def push_error(message)
        return unless @dialog

        @dialog.execute_script("window.RevestPlanner.error(#{JSON.generate(message)})")
      end

      def display_error(error)
        message = error.message.to_s
        return message if message.match?(/[áàâãéêíóôõúç]/i)

        puts "REVEST erro técnico: #{error.full_message}"
        return 'Os pontos do recorte não estão no mesmo plano. Tente ajustar a posição da paginação.' if message.match?(/points are not planar/i)

        'Ocorreu um erro interno. Consulte o Console Ruby para detalhes.'
      end

      def mm(value)
        value.to_f / 25.4
      end

      def cm(value)
        value.to_f / 2.54
      end

      def layout_rotation_radians
        (@state['rotation'].to_f + pattern_base_angle).degrees
      end

      def pattern_base_angle
        case @state['pattern']
        when 'diagonal' then 45.0
        when 'vertical' then 90.0
        else 0.0
        end
      end

      def normalize_degrees(value)
        normalized = value % 360.0
        normalized > 180.0 ? normalized - 360.0 : normalized
      end

      def pattern_reference_center
        width = cm(@state['width'])
        height = cm(@state['height'])
        joint = @state['dry_joint'] ? 0.0 : cm(@state['joint'])
        case @state['pattern']
        when 'checkerboard'
          span = [width, height].max + joint
          Core::Point2d.new(span / 2.0, span / 2.0)
        when 'french'
          span = [width, height].max * 2.0 + joint * 3.0
          Core::Point2d.new(span / 2.0, span / 2.0)
        when 'herringbone', 'chevron'
          Core::Point2d.new(0.0, 0.0)
        else
          Core::Point2d.new(width / 2.0, height / 2.0)
        end
      end

      def transformation_for(path)
        return Geom::Transformation.new unless path && path.length > 1

        Sketchup::InstancePath.new(path).transformation
      rescue ArgumentError
        Geom::Transformation.new
      end

      def face_area_m2
        raw_face_area_m2.round(2)
      end

      def raw_face_area_m2
        area = @adapter.respond_to?(:area) ? @adapter.area : @adapter.face.area(@adapter.transformation)
        area * 0.00064516
      end

      # Chamados pelas ferramentas de documentação (Tools::*), por isso precisam ser públicos.
      public :cancel_documentation_pick, :documentation_prompt, :finish_documentation_pick, :place_arrows,
             :arrow_tool_started, :arrow_tool_finished
    end

    class LayoutSelectionObserver < Sketchup::SelectionObserver
      def initialize(controller)
        @controller = controller
      end

      def onSelectionBulkChange(_selection); refresh; end
      def onSelectionAdded(_selection, _entity); refresh; end
      def onSelectionRemoved(_selection, _entity); refresh; end
      def onSelectionCleared(_selection); refresh; end

      private

      # Nenhuma exceção pode escapar de um observador do SketchUp.
      def refresh
        @controller.send(:schedule_selection_refresh)
      rescue StandardError => error
        puts "REVEST: #{error.message}"
      end
    end

    class LayoutModelObserver < Sketchup::ModelObserver
      def initialize(controller)
        @controller = controller
      end

      def onPreSaveModel(_model)
        @controller.send(:before_model_save)
      rescue StandardError
        nil
      end

      def onPostSaveModel(_model)
        @controller.send(:after_model_save)
      rescue StandardError
        nil
      end
    end
  end
end
