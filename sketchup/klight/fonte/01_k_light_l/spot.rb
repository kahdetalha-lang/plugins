module KahDetalha
  module KLight
    module Spot

      @spot_geo_cache = {}

      def self.spot_geo_key(apex_pt, normal, params)
        { apex: [apex_pt.x, apex_pt.y, apex_pt.z], normal: [normal.x, normal.y, normal.z],
          angle_deg: params[:angle_deg].to_f, length_cm: params[:length_cm].to_f,
          layers: params[:layers].to_i }
      end

      # Reconstrói o cone de um spot existente (usado pelo preview).
      # NÃO abre nem fecha operação — chame dentro de uma já aberta.
      # Mesmo raciocínio de rebuild_ribbon acima quanto a prev_mats e ao
      # cache de geometria (só retinta se ângulo/comprimento/camadas/posição
      # não mudaram desde a última reconstrução).
      def self.rebuild_spot(model, group, apex_pt, normal, params, prev_mats = nil, preview: false)
        return prev_mats || [] unless group.valid?

        render_params = preview ? Core.preview_params(params, :spot) : params
        geo_key = spot_geo_key(apex_pt, normal, render_params)
        if prev_mats && !prev_mats.empty? && @spot_geo_cache[group.entityID] == geo_key
          retint_spot_materials(prev_mats, render_params)
          model.active_view.invalidate
          return prev_mats
        end

        group.entities.clear!
        if prev_mats && !prev_mats.empty?
          prev_mats.each { |m| model.materials.remove(m) rescue nil }
        end
        result = build_spot_geo(group.entities, apex_pt, normal, render_params, model)
        @spot_geo_cache[group.entityID] = geo_key
        model.active_view.invalidate
        result[:materials] || []
      end

      # -----------------------------------------------------------------------
      # SPOT — helpers compartilhados entre criação e live preview
      # -----------------------------------------------------------------------

      # Mesmo raciocínio de ribbon_layer_rgb/alpha, pro facho do spot —
      # reusado por retint_spot_materials no preview ao vivo.
      def self.spot_layer_rgb(params)
        rgb_custom = params[:rgb_custom]
        if rgb_custom.is_a?(Array) && rgb_custom.size == 3
          rgb_custom.map { |v| v.to_i.clamp(0, 255) }
        else
          PRESETS_SPOT.fetch(params[:preset].to_s, PRESETS_SPOT['quente'])
        end
      end

      def self.spot_layer_alpha(l, n_layers, params)
        alpha_max = params[:alpha_max].to_f.clamp(0.05, 1.0)
        curve_exp = params[:curve_exp].to_f.clamp(0.5, 8.0)
        t = (l + 0.5) / n_layers.to_f
        (alpha_max * 0.72 * ((1.0 - t) ** curve_exp)).clamp(0.0, 1.0)
      end

      def self.retint_spot_materials(mats, params)
        r, g, b = spot_layer_rgb(params)
        n = mats.size
        mats.each_with_index do |mat, l|
          next unless mat.valid?
          mat.color = Sketchup::Color.new(r, g, b)
          mat.alpha = spot_layer_alpha(l, n, params)
        end
      end

      def self.build_spot_geo(ge, apex_pt, normal, params, model)
        angle_deg  = params[:angle_deg].to_f.clamp(2.0, 60.0)
        length_cm  = params[:length_cm].to_f.clamp(5.0, 500.0)
        n_layers   = params[:layers].to_i.clamp(6, 32)
        n_sides    = params[:preview_quality] ? 24 : 60

        r, g, b = spot_layer_rgb(params)

        n      = normal.normalize
        length = length_cm / 2.54
        visual_angle = [angle_deg * 1.42, 64.0].min
        half_a = visual_angle * Math::PI / 180.0
        radius_ref_length = [length, 12.0 / 2.54].min
        max_r  = radius_ref_length * Math.tan(half_a)

        ref = n.parallel?(Geom::Vector3d.new(0,0,1)) ?
              Geom::Vector3d.new(1,0,0) : Geom::Vector3d.new(0,0,1)
        u = n.cross(ref).normalize
        v = n.cross(u).normalize

        # top_frac: raio do topo (t=0) como fração do raio máximo. Antes era
        # "radius = max_r * t", ou seja, raio zero em t=0 — o facho nascia
        # de um ponto (bico). Com esse piso, o anel do topo já nasce com
        # raio real, então o facho começa como um círculo, não uma ponta.
        top_frac = 0.22
        top_offset = [[length * 0.012, 0.04].max, length * 0.08].min
        usable_length = [length - top_offset, length * 0.92].max
        # Crescimento LINEAR do raio (era t**0.78): com t espaçado uniforme-
        # mente ao longo do comprimento, um raio linear mantém o espaçamento
        # RADIAL entre anéis constante — mesmo princípio da fita de LED
        # (dist = l * layer_w). Antes, a curva de abertura deixava os anéis
        # bem afastados perto do ápice, e ali o salto de opacidade entre
        # camadas ficava visível como costura/anel (banding).
        rings = (0..n_layers).map do |l|
          t = l.to_f / n_layers
          center = apex_pt.offset(n, top_offset + usable_length * t)
          radius = max_r * (top_frac + (1.0 - top_frac) * t)
          (0...n_sides).map do |s|
            ang = (2 * Math::PI * s) / n_sides
            Geom::Point3d.new(
              center.x + u.x*Math.cos(ang)*radius + v.x*Math.sin(ang)*radius,
              center.y + u.y*Math.cos(ang)*radius + v.y*Math.sin(ang)*radius,
              center.z + u.z*Math.cos(ang)*radius + v.z*Math.sin(ang)*radius
            )
          end
        end

        # Curva de opacidade simples (mesma forma da fita de LED: alpha_max *
        # (1-t)**curve_exp), em vez da curva dupla anterior — que combinava
        # um expoente distorcido com um termo linear extra e podia gerar
        # uma derivada não suave, reforçando o efeito de anéis visíveis.
        # O fator 0.72 permanece: evita que o empilhamento de camadas do
        # cone (visualmente mais denso que a fita, por serem concêntricas)
        # fique opaco demais no centro do facho.
        mats = (0...n_layers).map do |l|
          mat       = model.materials.add(Core.next_mat_name("KS_#{l}"))
          mat.color = Sketchup::Color.new(r, g, b)
          mat.alpha = spot_layer_alpha(l, n_layers, params)
          mat
        end

        tol = 1e-4
        key = ->(p) { [(p.x/tol).round, (p.y/tol).round, (p.z/tol).round] }
        created = 0; all_edges = {}

        add_tri = lambda do |a, b, c, mat|
          return if [a,b,c].map { |p| key.(p) }.uniq.size < 3
          return if Core.tri_area(a, b, c) < Core::MIN_TRI_AREA
          face = nil
          begin; face = ge.add_face(a,b,c); rescue; return; end
          return unless face.is_a?(Sketchup::Face)
          face.material = mat; face.back_material = mat
          created += 1
          face.edges.each { |e| all_edges[e.entityID] = e if e.valid? }
        end

        (0...n_layers).each do |l|
          mat=mats[l]; hi=rings[l+1]
          lo=rings[l]
          (0...n_sides).each do |s|
            ns = (s+1) % n_sides
            if (l + s).even?
              # ring[0] agora tem raio real (não mais zero), então em vez de
              # abrir um leque direto do apex_pt até o segundo anel, fecha-se
              # primeiro um tampo circular pequeno com o próprio apex_pt como
              # centro — é isso que dá a leitura de círculo no início do facho.
              add_tri.call(lo[s], lo[ns], hi[ns], mat)
              add_tri.call(lo[s], hi[ns], hi[s],  mat)
            else
              add_tri.call(lo[s], lo[ns], hi[s],  mat)
              add_tri.call(lo[ns], hi[ns], hi[s], mat)
            end
          end
        end

        all_edges.values.each { |e| next unless e.valid?; e.hidden=true; e.soft=true; e.smooth=true }
        { created: created, materials: mats }
      end

      # -----------------------------------------------------------------------
      # SPOT — cone de luz fake, sempre reto para fora da face clicada
      # -----------------------------------------------------------------------
      # Geometria: cone de camadas semi-transparentes ao longo do vetor
      # normal, mesmo princípio de gradiente por camadas da fita LED.
      # Ativação: o usuário clica numa face da luminária no modelo.
      # -----------------------------------------------------------------------
      def self.create_spot(model, apex_pt, normal, params)
        model.start_operation('K.Light — Criar Spot', true)
        begin
          group       = model.entities.add_group
          group.name  = "K.Spot_#{params[:preset]}"
          group.layer = Core.ensure_tag(model)

          result = build_spot_geo(group.entities, apex_pt, normal, params, model)

          if result[:created] == 0 || !group.valid?
            group.erase! if group.valid?
            model.abort_operation
            UI.messagebox("K.Light: não foi possível gerar o spot.")
            return nil
          end

          rgb_custom = params[:rgb_custom]
          group.set_attribute(ATTR_DICT, 'kind',      'spot')
          # .to_f: apex_pt.x/y/z e normal.x/y/z são Length, não Float — o
          # to_s sobrescrito da Length (formata com unidade, tipo 10")
          # quebra o JSON gerado se não convertermos antes. Ver nota igual
          # em led.rb#store_ribbon_attrs.
          group.set_attribute(ATTR_DICT, 'apex',      JSON.generate([apex_pt.x.to_f, apex_pt.y.to_f, apex_pt.z.to_f]))
          group.set_attribute(ATTR_DICT, 'normal',    JSON.generate([normal.x.to_f, normal.y.to_f, normal.z.to_f]))
          group.set_attribute(ATTR_DICT, 'angle_deg', params[:angle_deg].to_f)
          group.set_attribute(ATTR_DICT, 'length_cm', params[:length_cm].to_f)
          group.set_attribute(ATTR_DICT, 'layers',    params[:layers].to_i)
          group.set_attribute(ATTR_DICT, 'alpha_max', params[:alpha_max].to_f)
          group.set_attribute(ATTR_DICT, 'curve_exp', params[:curve_exp].to_f)
          group.set_attribute(ATTR_DICT, 'preset',    params[:preset].to_s)
          group.set_attribute(ATTR_DICT, 'rgb_custom',JSON.generate(rgb_custom))
          group.set_attribute(ATTR_DICT, 'version',   PLUGIN_VERSION)

          model.commit_operation
          group
        rescue => err
          model.abort_operation
          UI.messagebox("K.Light erro (spot):\n#{err.message}\n\n#{err.backtrace.first(3).join("\n")}")
          nil
        end
      end

    # =========================================================================
    # FERRAMENTA DE CLIQUE — Spot (clique na face da luminária)
    # =========================================================================
    class SpotPickTool
      def initialize(params)
        @params = params
        @ip     = nil
      end

      def activate
        Sketchup.status_text = 'K.Light Spot: clique na FACE da luminária — ESC para cancelar'
      end

      def deactivate(view); view.invalidate; end

      def onMouseMove(_flags, x, y, view)
        @ip = Sketchup::InputPoint.new
        @ip.pick(view, x, y)
        view.invalidate
      end

      def draw(view)
        return unless @ip && @ip.face
        view.draw_points([@ip.position], 8, 1, 'red') rescue nil
      end

      def onLButtonUp(_flags, x, y, view)
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)

        # Precisa de um ponto no modelo — face ou não
        unless ip.valid?
          Sketchup.status_text = 'K.Light Spot: ponto inválido. Tente novamente.'
          return
        end

        model = view.model

        # Direção SEMPRE perpendicular ao eixo azul (Z), ou seja, reto para
        # baixo — independente da face clicada, da câmera ou de qualquer
        # inclinação do componente. É exatamente isso que faz o spot
        # parecer fisicamente correto numa luminária de teto.
        straight = Geom::Vector3d.new(0, 0, -1)
        straight.reverse! if @params[:invert_direction]

        # Puxa o apex ligeiramente para dentro do teto (0.5 mm) para que
        # a ponta do cone fique embutida na face e não haja gap visual.
        apex_pt = ip.position.offset(straight, -0.5 / 25.4)

        rgb = @params[:rgb_custom]
        rgb = rgb.map(&:to_i) if rgb.is_a?(Array)

        group = Spot.create_spot(model, apex_pt, straight, {
          angle_deg:  @params[:angle_deg],
          length_cm:  @params[:length_cm],
          layers:     @params[:layers],
          alpha_max:  @params[:alpha_max],
          curve_exp:  @params[:curve_exp],
          preset:     @params[:preset].to_s,
          rgb_custom: rgb
        })

        if group
          model.selection.clear
          model.selection.add(group)
        end

        model.active_view.invalidate
        model.select_tool(nil)
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end
    end

    # SPOT — abre o diálogo já na aba Spot
    def self.cmd_create_spot
      model = Sketchup.active_model
      Dialog.show(
        ->(_p) {},
        nil,
        ->(p) { model.select_tool(SpotPickTool.new(p)) },
        init: { tab: 'spot' }
      )
    end

    end # Spot
  end
end
