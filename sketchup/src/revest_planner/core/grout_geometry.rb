# frozen_string_literal: true

module RevestPlanner
  module Core
    # Faixas de rejunte calculadas em 2D, sem depender do recorte do SketchUp (que fica lento a
    # cada peça "furada" numa face grande). Cada peça ganha um anel com meia junta de largura; os
    # anéis de peças vizinhas se encontram no eixo da junta e, juntos, preenchem todos os vãos.
    # O anel é dividido em trapézios (um por lado da peça), recortados pelas regiões da superfície.
    module GroutGeometry
      module_function

      # `pieces`: Core::Piece; `regions`: polígonos convexos da superfície; `joint`: largura da junta.
      def polygons(pieces, regions, joint, pattern)
        return [] unless joint.positive?

        region_bounds = regions.map { |region| [region, region.bounds] }
        bounds = [region_bounds.map { |item| item[1][0] }.min, region_bounds.map { |item| item[1][1] }.min,
                  region_bounds.map { |item| item[1][2] }.max, region_bounds.map { |item| item[1][3] }.max]
        index = LayoutEngine::RegionIndex.new(region_bounds, bounds)
        pieces.each_with_object([]) do |piece, output|
          inner = piece.source_polygon.counter_clockwise
          outer = outer_outline(inner, joint * 0.5, pattern)
          next unless outer

          count = inner.points.length
          count.times do |position|
            following = (position + 1) % count
            quad = [inner.points[position], inner.points[following], outer[following], outer[position]]
            next if twice_area(quad).abs <= 1.0e-10

            ring = Polygon2d.new(quad)
            ring_bounds = ring.bounds
            index.candidates(ring_bounds).each do |region, box|
              next unless overlap?(ring_bounds, box)

              clipped = Clipper.intersection(ring, region)
              output << clipped if clipped && clipped.area > LayoutEngine::MIN_FRAGMENT_AREA
            end
          end
        end
      end

      # Contorno externo do anel. Padrões com recuo radial (Chevron) voltam ao contorno original;
      # os de junta uniforme usam um recuo paralelo (esquadria) de meia junta. Na Espinha as peças
      # de cada par encostam sem junta, então a faixa tem a junta inteira: o excesso fica sob as
      # peças ou sobre outra faixa de rejunte (mesma cor), sem aparecer.
      def outer_outline(inner, half, pattern)
        case pattern.to_sym
        when :chevron then radial_outline(inner, half * 2.0)
        when :herringbone then miter_outline(inner, half * 2.0)
        else miter_outline(inner, half)
        end
      end

      def miter_outline(polygon, distance)
        points = polygon.points
        normals = points.each_index.map do |position|
          start = points[position]
          finish = points[(position + 1) % points.length]
          dx = finish.x - start.x
          dy = finish.y - start.y
          length = Math.hypot(dx, dy)
          return nil if length <= 1.0e-12

          Point2d.new(dy / length, -dx / length) # normal para fora (polígono anti-horário)
        end
        points.each_index.map do |position|
          before = normals[position - 1]
          after = normals[position]
          denominator = 1.0 + (before.x * after.x) + (before.y * after.y)
          return nil if denominator <= 1.0e-6

          factor = distance / denominator
          points[position] + Point2d.new((before.x + after.x) * factor, (before.y + after.y) * factor)
        end
      end

      # Inverso do `radial_inset` do Chevron: cada vértice foi puxado para o centro por
      # min(junta/2, 20% da distância); aqui ele volta para onde estava.
      def radial_outline(polygon, joint)
        points = polygon.points
        center = Point2d.new(points.sum(&:x) / points.length.to_f, points.sum(&:y) / points.length.to_f)
        distance = joint * 0.5
        points.map do |point|
          vector = point - center
          current = Math.hypot(vector.x, vector.y)
          return nil if current <= 1.0e-12

          original = [current + distance, current / 0.8].min
          center + vector * (original / current)
        end
      end

      def twice_area(points)
        points.each_index.sum do |position|
          following = points[(position + 1) % points.length]
          (points[position].x * following.y) - (following.x * points[position].y)
        end
      end

      def overlap?(first, second)
        first[2] >= second[0] && second[2] >= first[0] && first[3] >= second[1] && second[3] >= first[1]
      end
    end
  end
end
