require 'json'

module KahDetalha
  module KLight
    module Core

      def self.ensure_tag(model)
        tag = model.layers[TAG_NAME] || model.layers.add(TAG_NAME)
        tag.color = Sketchup::Color.new(*TAG_COLOR) if tag.respond_to?(:color=)
        tag
      end

      # Sequência monotônica pra nomear materiais (KL_/KS_) sem depender de
      # rand() — com muitas reconstruções ao vivo (preview debounced), a
      # chance de colisão de nome com rand(99999) deixa de ser desprezível,
      # e uma colisão pode fazer o SketchUp reaproveitar/renomear um
      # material errado. Um contador simples elimina essa classe de bug.
      @material_seq = 0
      def self.next_mat_name(prefix)
        @material_seq += 1
        "#{prefix}_#{@material_seq}"
      end

      # Limite de segurança: acima disso, o cálculo de geometria fica pesado
      # demais para o motor do SketchUp processar com segurança numa única
      # operação. Em vez de deixar travar/crashar, avisamos o usuário.
      MAX_EDGES = 4000

      # Mesmo raciocínio para o nº total de faces geradas pela malha.
      MAX_FACES = 80_000

      # O preview deve responder durante o arraste; a qualidade final só é
      # criada ao confirmar. Estes limites reduzem centenas de milhares de
      # chamadas Ruby -> SketchUp por segundo em modelos complexos.
      PREVIEW_LED_LAYERS  = 8
      PREVIEW_SPOT_LAYERS = 8
      PREVIEW_HALO_BANDS  = 10
      PREVIEW_HALO_PIXELS = 160

      # Área mínima (em pol²) para considerar um triângulo válido. Abaixo
      # disso é uma sliver (degenerada) e é melhor pular do que entregar
      # pro motor de geometria do SketchUp.
      MIN_TRI_AREA = 1e-8

      def self.tri_area(a, b, c)
        (b - a).cross(c - a).length * 0.5
      end

      # Atributos do modelo podem vir de arquivos antigos ou de modelos de
      # terceiros. Eles nunca devem ser avaliados como Ruby: além de poder
      # executar código, um valor corrompido derrubaria a edição da luz.
      MAX_SERIALIZED_ATTRIBUTE_BYTES = 1_048_576

      def self.json_array(value, expected_length: nil, max_items: 10_000)
        parsed = if value.is_a?(String)
          return nil if value.bytesize > MAX_SERIALIZED_ATTRIBUTE_BYTES
          JSON.parse(value)
        elsif value.is_a?(Array)
          # Alguns Attribute Dictionaries antigos do SketchUp devolvem o
          # Array diretamente, em vez da string JSON usada pelas versões
          # novas. Aceitamos apenas a estrutura de dados, nunca código.
          value
        else
          return nil
        end
        return nil unless parsed.is_a?(Array)
        return nil if expected_length && parsed.length != expected_length
        return nil if parsed.length > max_items

        parsed
      rescue JSON::ParserError, TypeError
        nil
      end

      def self.numeric_triplet(value)
        values = numeric_array(value, expected_length: 3)
        values
      end

      def self.numeric_array(value, expected_length: nil, max_items: 10_000)
        values = json_array(value, expected_length: expected_length, max_items: max_items)
        values ||= legacy_numeric_list(value, expected_length: expected_length, max_items: max_items)
        return nil unless values

        converted = values.map { |item| safe_number(item) }
        return nil if converted.any?(&:nil?)

        converted
      end

      def self.safe_number(value)
        number = if value.is_a?(Numeric)
          value.to_f
        elsif value.is_a?(String) && value.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)
          Float(value)
        end
        return nil unless number && number.finite?

        number
      rescue ArgumentError, TypeError
        nil
      end

      def self.numeric_point_list(value, min_items: 2, max_items: MAX_EDGES + 1)
        points = json_array(value, max_items: max_items)
        converted = points && points.map { |point| numeric_array(point, expected_length: 3) }
        if !converted || converted.any?(&:nil?)
          converted = legacy_numeric_points(value, max_items: max_items)
        end
        return nil unless converted && converted.length >= min_items
        return nil if converted.any?(&:nil?)

        converted
      end

      # Compatibilidade estrita com atributos gerados antes da migração para
      # JSON. Aceita somente listas de números; não interpreta constantes,
      # chamadas de método nem qualquer expressão Ruby.
      def self.legacy_numeric_list(value, expected_length: nil, max_items: 10_000)
        return nil unless value.is_a?(String)
        source = value.strip
        return nil if source.bytesize > MAX_SERIALIZED_ATTRIBUTE_BYTES
        return nil unless source.start_with?('[') && source.end_with?(']')

        items = source[1...-1].split(',').map { |item| safe_number(item.strip) }
        return nil if items.any?(&:nil?) || items.length > max_items
        return nil if expected_length && items.length != expected_length

        items
      end

      def self.legacy_numeric_points(value, max_items: MAX_EDGES + 1)
        return nil unless value.is_a?(String)
        source = value.strip
        return nil if source.bytesize > MAX_SERIALIZED_ATTRIBUTE_BYTES
        rows = source.scan(/\[\s*([^\[\]]+)\s*\]/).flatten
        return nil if rows.empty? || rows.length > max_items

        points = rows.map { |row| legacy_numeric_list("[#{row}]", expected_length: 3) }
        points.any?(&:nil?) ? nil : points
      end

      def self.preview_params(params, kind)
        preview = params.dup
        preview[:preview_quality] = true
        case kind
        when :ribbon
          preview[:layers] = [preview[:layers].to_i, PREVIEW_LED_LAYERS].min
        when :spot
          preview[:layers] = [preview[:layers].to_i, PREVIEW_SPOT_LAYERS].min
        when :backlight
          preview[:halo_bands] = PREVIEW_HALO_BANDS
          preview[:halo_pixels] = PREVIEW_HALO_PIXELS
        end
        preview
      end

    end # Core
  end
end
