# frozen_string_literal: true

module RevestPlanner
  module SketchupAdapter
    class LayoutExporter
      LIME = Sketchup::Color.new(206, 214, 41)
      INK = Sketchup::Color.new(28, 31, 34)
      MUTED = Sketchup::Color.new(105, 110, 116)
      LINE = Sketchup::Color.new(218, 220, 222)
      ROW_SHADE = Sketchup::Color.new(246, 246, 246)

      # `scenes`: nomes das cenas do modelo (salvo em `model_path`) que viram páginas extras,
      # uma por cena, depois da página do quantitativo.
      def initialize(data:, texture_path: nil, model_path: nil, scenes: [], include_quantitative: true)
        @data = data
        @texture_path = texture_path
        @model_path = model_path
        @scenes = Array(scenes)
        @include_quantitative = include_quantitative
      end

      attr_reader :scenes

      def export(path)
        start
        @scenes.each { |scene_name| add_scene(scene_name) }
        save(path)
      end

      # Em etapas (start → add_scene… → save): entre uma e outra a janela do plugin consegue
      # mostrar o progresso, em vez de o SketchUp parecer travado durante toda a exportação.
      def start
        raise 'A API do LayOut não está disponível nesta versão do SketchUp.' unless defined?(Layout::Document)

        @document = Layout::Document.new
        configure_page(@document)
        page = @document.pages.first
        @layer = @document.layers.first
        if @include_quantitative
          page.name = 'Quantitativo' if page.respond_to?(:name=)
          add_header(@document, @layer, page)
          add_table(@document, @layer, page)
          add_product_panel(@document, @layer, page)
        else
          # Sem o quantitativo, a página que todo documento novo já traz recebe a primeira cena.
          @spare_page = page
        end
        self
      end

      def add_scene(scene_name)
        return unless scenes_available?

        add_scene_page(@document, @layer, scene_name)
      end

      def save(path)
        @document.set_attribute('RevestPlanner', 'layout_group_id', @data['group_id'].to_i) if @document.respond_to?(:set_attribute)
        @document.save(path)
        path
      end

      private

      def scenes_available?
        !@scenes.empty? && !@model_path.to_s.empty? && File.file?(@model_path)
      end

      def configure_page(document)
        info = document.page_info
        info.width = 11.69 if info.respond_to?(:width=)
        info.height = 8.27 if info.respond_to?(:height=)
        # Documento novo da API começa em resolução baixa: viewports (textura e texto da tag) saem
        # pixelados e ilegíveis. Alta resolução na tela e na saída (impressão/PDF).
        if defined?(Layout::PageInfo::RESOLUTION_HIGH)
          info.display_resolution = Layout::PageInfo::RESOLUTION_HIGH if info.respond_to?(:display_resolution=)
          info.output_resolution = Layout::PageInfo::RESOLUTION_HIGH if info.respond_to?(:output_resolution=)
        end
        document.units = Layout::Document::DECIMAL_CENTIMETERS
      end

      def add_header(document, layer, page)
        document.add_entity(text_entity('R E V E S T I M E N T O', [0.65, 0.42, 1.65, 0.2], 7.5, true, INK), layer, page)
        document.add_entity(text_entity('D E T A L H A M E N T O   E X E C U T I V O', [8.75, 0.42, 2.3, 0.2], 7.0, false, MUTED), layer, page)
        document.add_entity(text_entity('QUANTITATIVO', [0.65, 0.92, 7.7, 0.52], 25, true, INK), layer, page)

        line = Layout::Rectangle.new(Geom::Bounds2d.new(2.35, 0.51, 6.0, 0.012))
        style = line.style
        style.filled = true if style.respond_to?(:filled=)
        style.fill_color = LINE if style.respond_to?(:fill_color=)
        style.stroked = false if style.respond_to?(:stroked=)
        line.style = style
        document.add_entity(line, layer, page)
      end

      def add_table(document, layer, page)
        rows = table_rows
        left = 0.65
        top = 1.82
        width = 7.35
        row_height = 0.49
        add_alternating_row_backgrounds(document, layer, page, left, top, width, row_height, rows.length)
        bounds = Geom::Bounds2d.new(left, top, width, 5.75)
        table = Layout::Table.new(bounds, rows.length, 2)
        table.get_column(0).width = 2.95
        table.get_column(1).width = 4.4
        rows.each_with_index do |(label, value), index|
          table.get_row(index).height = row_height
          table[index, 0].data = cell_text(label.upcase, true, INK, 9.0)
          table[index, 1].data = cell_text(value, false, INK, 9.0)
          style_row(table, index)
        end
        document.add_entity(table, layer, page)
      end

      def add_alternating_row_backgrounds(document, layer, page, left, top, width, row_height, count)
        count.times do |index|
          next unless index.even?

          background = Layout::Rectangle.new(Geom::Bounds2d.new(left, top + index * row_height, width, row_height))
          style = background.style
          style.filled = true if style.respond_to?(:filled=)
          style.fill_color = ROW_SHADE if style.respond_to?(:fill_color=)
          style.stroked = false if style.respond_to?(:stroked=)
          background.style = style
          document.add_entity(background, layer, page)
        end
      end

      def table_rows
        [
          ['REVESTIMENTO', @data['name'].to_s],
          ['Dimensão da peça', "#{@data['dimensions']} cm"],
          ['Espessura', "#{@data['thickness']} mm"],
          ['Junta', @data['joint'].to_s],
          ['Padrão de paginação', @data['pattern_name'].to_s],
          ['Área revestida', "#{@data['area']} m²"],
          ['Percentual de perda', "#{@data['waste']}%"],
          ['Quantidade de peças', "#{@data['purchase_total']} un"],
          ['Peças por caixa', blank_or_unit(@data['pieces_per_box'], 'un')],
          ['Caixas para compra', blank_or_unit(@data['boxes_needed'], 'cx')],
          ['Área total comprada', blank_or_unit(@data['purchased_area'], 'm²')]
        ]
      end

      def blank_or_unit(value, unit)
        value.to_s.empty? ? '—' : "#{value} #{unit}"
      end

      def cell_text(value, bold, color, size)
        text = Layout::FormattedText.new(value.to_s.empty? ? '—' : value.to_s, Geom::Point2d.new(0, 0), Layout::FormattedText::ANCHOR_TYPE_CENTER_LEFT)
        style = Layout::Style.new
        style.font_size = size
        style.text_color = color
        style.text_bold = bold if style.respond_to?(:text_bold=)
        style.font_family = 'Arial' if style.respond_to?(:font_family=)
        text.apply_style(style)
        text
      end

      def style_row(table, index)
        edge = Layout::Style.new
        edge.stroked = true
        edge.stroke_color = LINE
        edge.stroke_width = 0.28
        table.get_row(index).bottom_edge_style = edge
      end

      def add_product_panel(document, layer, page)
        if @texture_path && File.file?(@texture_path)
          image = Layout::Image.new(@texture_path, Geom::Bounds2d.new(8.55, 2.0, 2.45, 3.25))
          document.add_entity(image, layer, page)
        end

        marker = Layout::Rectangle.new(Geom::Bounds2d.new(8.55, 5.58, 0.5, 0.025))
        marker_style = marker.style
        marker_style.filled = true if marker_style.respond_to?(:filled=)
        marker_style.fill_color = LIME if marker_style.respond_to?(:fill_color=)
        marker_style.stroked = false if marker_style.respond_to?(:stroked=)
        marker.style = marker_style
        document.add_entity(marker, layer, page)

        name = @data['name'].to_s.empty? ? 'REVESTIMENTO' : @data['name'].to_s.upcase
        manufacturer = @data['manufacturer'].to_s.empty? ? 'FABRICANTE' : @data['manufacturer'].to_s.upcase
        document.add_entity(text_entity(name, [8.55, 5.76, 2.45, 0.3], 9.0, true, INK), layer, page)
        document.add_entity(text_entity(manufacturer, [8.55, 6.08, 2.45, 0.24], 7.4, false, MUTED), layer, page)
      rescue StandardError => error
        puts "REVEST não inseriu o painel do revestimento no LayOut: #{error.message}"
      end

      # Uma página por cena marcada: título com o nome da cena e a vista do modelo ocupando a folha.
      def add_scene_page(document, layer, scene_name)
        info = document.page_info
        width = info.respond_to?(:width) ? info.width : 11.69
        height = info.respond_to?(:height) ? info.height : 8.27
        margin = 0.45
        top = 0.95
        begin
          page = @spare_page || document.pages.add(scene_name.to_s)
          if @spare_page
            page.name = scene_name.to_s if page.respond_to?(:name=)
            @spare_page = nil
          end
          document.add_entity(text_entity(scene_name.to_s.upcase, [margin, 0.38, width - 2 * margin, 0.36], 14, true, INK),
                              layer, page)
          viewport = Layout::SketchUpModel.new(@model_path,
                                               Geom::Bounds2d.new(margin, top, width - 2 * margin, height - top - margin))
          index = viewport.scenes.index(scene_name.to_s)
          viewport.current_scene = index if index
          if viewport.respond_to?(:render_mode=) && defined?(Layout::SketchUpModel::HYBRID_RENDER)
            viewport.render_mode = Layout::SketchUpModel::HYBRID_RENDER
          end
          # Fundo transparente (sem o céu/cor de fundo do estilo). Os eixos são desligados na própria
          # cena antes de exportar (Controller#hide_axes_in_scenes).
          viewport.display_background = false if viewport.respond_to?(:display_background=)
          document.add_entity(viewport, layer, page)
          # Sem isso o viewport é salvo "nunca renderizado" e o LayOut mostra só uma prévia parada,
          # que parece uma imagem. Renderizar aqui deixa o viewport vivo ao abrir o arquivo.
          viewport.render if viewport.respond_to?(:render)
          add_vector_tags(document, layer, page, viewport, scene_name.to_s)
        rescue StandardError => error
          puts "REVEST não inseriu a cena \"#{scene_name}\" no LayOut: #{error.message}"
        end
      end

      TAG_PAPER = Sketchup::Color.new(244, 243, 240)
      TAG_INK = Sketchup::Color.new(35, 39, 41)

      # As tags do REVEST são texto 3D no modelo: no viewport viram imagem e perdem nitidez.
      # Aqui cada tag visível na vista é redesenhada com entidades nativas do LayOut (fundo, linhas
      # e texto em vetor), no mesmo lugar e tamanho, cobrindo a versão rasterizada.
      def add_vector_tags(document, layer, page, viewport, scene_name)
        return unless viewport.respond_to?(:model_to_paper_point)

        model = Sketchup.active_model
        scene = model.pages[scene_name]
        model.entities.grep(Sketchup::Group).each do |group|
          next unless group.get_attribute('RevestPlanner', 'layout_data')

          tag = group.entities.grep(Sketchup::Group).find { |child| child.get_attribute('RevestPlanner', 'documentation_key') == 'tag' }
          next unless tag && tag.visible?
          # Respeita a etiqueta da documentação: oculta na cena = sem tag no LayOut.
          next unless layer_visible_in_scene?(tag.layer, scene)

          block = tag.entities.grep(Sketchup::Group).find { |item| item.get_attribute('RevestPlanner', 'tag_layout') }
          next unless block

          spec = JSON.parse(block.get_attribute('RevestPlanner', 'tag_layout'))
          to_world = group.transformation * tag.transformation * block.transformation
          result = add_vector_tag(document, layer, page, viewport, spec, to_world)
          puts "REVEST tag vetorial na página \"#{page.name}\": #{result == :ok ? 'ok' : "não inserida (#{result})"}"
        rescue StandardError => error
          puts "REVEST não redesenhou uma tag no LayOut: #{error.class}: #{error.message}"
        end
      end

      def layer_visible_in_scene?(sketchup_layer, scene)
        return true unless sketchup_layer
        if scene && scene.respond_to?(:use_hidden_layers?) && scene.use_hidden_layers?
          !Array(scene.layers).include?(sketchup_layer)
        else
          sketchup_layer.visible?
        end
      end

      def add_vector_tag(document, layer, page, viewport, spec, to_world)
        left, top, right, bottom = spec['box'].map(&:to_f)
        paper = ->(x, y) { viewport.model_to_paper_point(Geom::Point3d.new(x, y, 0.0).transform(to_world)) }
        origin = paper.call(left, top)
        along = paper.call(right, top)
        down = paper.call(left, bottom)
        ex = [along.x - origin.x, along.y - origin.y]
        ey = [down.x - origin.x, down.y - origin.y]
        width = Math.hypot(*ex)
        height = Math.hypot(*ey)
        return :muito_pequena if width < 0.05 || height < 0.02
        # Só em vistas em que a tag aparece "de frente" e na horizontal (plantas e elevações
        # ortogonais); em perspectiva fica a versão do modelo.
        return :vista_nao_frontal unless ex[1].abs < width * 0.02 && ex[0].positive? && ey[0].abs < height * 0.02 && ey[1].positive?

        bounds = viewport.bounds
        inside = origin.x >= bounds.upper_left.x && origin.y >= bounds.upper_left.y &&
                 origin.x + width <= bounds.lower_right.x && origin.y + height <= bounds.lower_right.y
        return :fora_do_viewport unless inside

        scale = width / (right - left) # polegadas de papel por unidade do projeto da tag
        px = ->(x) { origin.x + (x - left) * scale }
        py = ->(y) { origin.y + (top - y) * scale }

        box = Geom::Bounds2d.new(origin.x, origin.y, width, height)
        radius = spec['radius'].to_f * scale
        # Retângulo arredondado: o raio tem de ir no construtor (Rectangle.new(bounds, TYPE_ROUNDED)
        # sem raio dá ArgumentError — era isso que impedia a tag vetorial de aparecer).
        background = begin
          Layout::Rectangle.new(box, Layout::Rectangle::TYPE_ROUNDED, radius)
        rescue StandardError
          Layout::Rectangle.new(box)
        end
        fill_only(background, TAG_PAPER)
        parts = [background] # fundo primeiro: fica atrás no grupo

        Array(spec['rects']).each do |x1, y1, x2, y2|
          x_min, x_max = [px.call(x1.to_f), px.call(x2.to_f)].minmax
          y_min, y_max = [py.call(y1.to_f), py.call(y2.to_f)].minmax
          # Linha, barra lateral e separador são retângulos finíssimos: como preenchimento o LayOut
          # não chega a desenhá-los. Viram um traço no eixo do retângulo, com espessura mínima.
          horizontal = (x_max - x_min) >= (y_max - y_min)
          thickness = horizontal ? y_max - y_min : x_max - x_min
          start, finish = if horizontal
                            mid = (y_min + y_max) / 2.0
                            [Geom::Point2d.new(x_min, mid), Geom::Point2d.new(x_max, mid)]
                          else
                            mid = (x_min + x_max) / 2.0
                            [Geom::Point2d.new(mid, y_min), Geom::Point2d.new(mid, y_max)]
                          end
          line = Layout::Path.new(start, finish)
          style = line.style
          style.filled = false if style.respond_to?(:filled=)
          style.stroked = true if style.respond_to?(:stroked=)
          style.stroke_color = TAG_INK if style.respond_to?(:stroke_color=)
          style.stroke_width = [thickness * 72.0, 0.5].max if style.respond_to?(:stroke_width=) # pontos
          line.style = style
          parts << line
        end

        font = spec['font'].to_s.empty? ? 'Arial' : spec['font'].to_s
        Array(spec['texts']).each do |item|
          text = item['spaced'] ? item['text'].to_s.chars.join(' ') : item['text'].to_s
          cap_height = item['height'].to_f * scale        # altura das maiúsculas no papel (pol.)
          size = cap_height / 0.72 * 72.0                  # tamanho da fonte em pontos
          em = size / 72.0
          anchor = Geom::Point2d.new(px.call(item['left'].to_f), py.call(item['top'].to_f) - em * 0.2)
          entity = Layout::FormattedText.new(text, anchor, Layout::FormattedText::ANCHOR_TYPE_TOP_LEFT)
          style = Layout::Style.new
          style.font_size = size
          style.text_color = TAG_INK
          style.font_family = font if style.respond_to?(:font_family=)
          style.text_bold = false if style.respond_to?(:text_bold=)
          entity.apply_style(style)
          parts << entity
        end
        # Tudo num grupo do LayOut: a tag se move/edita como uma peça só.
        begin
          document.add_entity(Layout::Group.new(parts), layer, page)
        rescue StandardError => error
          puts "REVEST: não agrupou a tag no LayOut (#{error.message}); inserindo os elementos soltos."
          parts.each { |part| document.add_entity(part, layer, page) }
        end
        :ok
      end

      def fill_only(entity, color)
        style = entity.style
        style.filled = true if style.respond_to?(:filled=)
        style.fill_color = color if style.respond_to?(:fill_color=)
        style.stroked = false if style.respond_to?(:stroked=)
        entity.style = style
      end

      def text_entity(value, bounds, size, bold, color)
        text = Layout::FormattedText.new(value, Geom::Bounds2d.new(*bounds))
        style = Layout::Style.new
        style.font_size = size
        style.text_color = color
        style.text_bold = bold if style.respond_to?(:text_bold=)
        style.font_family = 'Arial' if style.respond_to?(:font_family=)
        text.apply_style(style)
        text
      end
    end
  end
end
