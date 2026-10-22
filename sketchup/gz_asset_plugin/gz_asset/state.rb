# encoding: UTF-8
# 材质 / 视觉设置 / 灯光 的状态采集、比对、回滚。
# 按 SketchUp 2020 自带的 Ruby 2.5 写，不用更新的语法。
require 'json'
require 'digest'
require 'fileutils'

module GZAsset
  module State
    FORMAT = 1
    ENSCAPE = 'Enscape'.freeze
    TAG_RE = /<([A-Za-z]+)>([^<>]*)<\/\1>/
    TEX_RE = /<(\w*Texture)>(.*?)<\/\1>/m
    TEX_EXTS = %w[.jpg .jpeg .png .bmp .tif .tiff .tga].freeze

    module_function

    # ---------------- 属性值 <-> JSON ----------------

    def dump_value(v)
      case v
      when String, Integer, Float, TrueClass, FalseClass, NilClass then v
      when Array then v.map { |x| dump_value(x) }
      when Geom::Point3d then { '__t' => 'pt', 'v' => v.to_a }
      when Geom::Vector3d then { '__t' => 'vec', 'v' => v.to_a }
      when Time then { '__t' => 'time', 'v' => v.to_i }
      when Sketchup::Color then { '__t' => 'color', 'v' => v.to_a }
      else { '__t' => 'unsupported', 'v' => v.class.name }
      end
    end

    def load_value(v)
      if v.is_a?(Hash) && v.key?('__t')
        case v['__t']
        when 'pt' then Geom::Point3d.new(v['v'])
        when 'vec' then Geom::Vector3d.new(v['v'])
        when 'time' then Time.at(v['v'])
        when 'color' then Sketchup::Color.new(*v['v'])
        else :unsupported
        end
      elsif v.is_a?(Array)
        v.map { |x| load_value(x) }
      else
        v
      end
    end

    # 实体上的全部属性字典；prefix 不为空时只取以它开头的字典
    def dicts_of(entity, prefix = nil)
      out = {}
      dicts = entity.attribute_dictionaries
      return out unless dicts
      dicts.each do |d|
        next if prefix && !d.name.start_with?(prefix)
        h = {}
        d.each_pair { |k, v| h[k.to_s] = dump_value(v) }
        out[d.name] = h
      end
      out
    end

    # ---------------- 采集 ----------------

    def capture(model, dir, label = '')
      FileUtils.mkdir_p(File.join(dir, 'textures'))
      mats = []
      model.materials.each_with_index { |m, i| mats << capture_material(m, dir, i) }
      {
        'format' => FORMAT,
        'label' => label.to_s,
        'model_title' => model.title.to_s,
        'model_path' => model.path.to_s,
        'created_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'sketchup' => Sketchup.version.to_s,
        'materials' => mats,
        'model_dicts' => dicts_of(model, ENSCAPE),
        'entities' => capture_entities(model)
      }
    end

    def capture_material(m, dir, i)
      rec = {
        'name' => m.name,
        'color' => m.color.to_a,
        'alpha' => m.alpha,
        'colorize_type' => (m.respond_to?(:colorize_type) ? m.colorize_type : nil),
        'colorize_deltas' => (m.respond_to?(:colorize_deltas) ? m.colorize_deltas : nil),
        'texture' => nil,
        'dicts' => dicts_of(m)
      }
      t = m.texture
      if t
        src = t.filename.to_s
        ext = File.extname(src).downcase
        ext = '.png' unless TEX_EXTS.include?(ext)
        rel = format('textures/%04d%s', i, ext)
        abs = File.join(dir, rel)
        ok = begin
          t.write(abs)
        rescue StandardError
          false
        end
        ok = ok && File.exist?(abs)
        rec['texture'] = {
          'file' => src.split(/[\\\/]/).last.to_s,
          'width' => t.width,
          'height' => t.height,
          'copy' => ok ? rel : nil,
          'md5' => ok ? Digest::MD5.file(abs).hexdigest : nil
        }
      end
      rec
    end

    # 灯光等带 Enscape 字典的组件（定义和实例都可能挂）
    def capture_entities(model)
      out = []
      model.definitions.each do |d|
        next if d.image?
        dd = dicts_of(d, ENSCAPE)
        out << { 'key' => "def:#{d.name}", 'label' => d.name, 'dicts' => dd } unless dd.empty?
        d.instances.each do |inst|
          di = dicts_of(inst, ENSCAPE)
          next if di.empty?
          out << { 'key' => "pid:#{inst.persistent_id}", 'label' => d.name, 'dicts' => di }
        end
      end
      out
    end

    def save(state, dir)
      File.write(File.join(dir, 'state.json'),
                 JSON.pretty_generate(state, allow_nan: true), mode: 'w:UTF-8')
    end

    def load(dir_or_file)
      path = File.directory?(dir_or_file) ? File.join(dir_or_file, 'state.json') : dir_or_file
      JSON.parse(File.read(path, mode: 'r:BOM|UTF-8'), allow_nan: true)
    end

    # ---------------- 比对 ----------------
    # 返回变更列表；restore_key 为空的项（快照之后新增的）回滚时不动

    def compare(old, cur)
      out = []
      om = by(old['materials'], 'name')
      cm = by(cur['materials'], 'name')
      (om.keys | cm.keys).each do |name|
        a = om[name]
        b = cm[name]
        if a.nil?
          out << change('材质', name, '快照之后新增', [], nil)
        elsif b.nil?
          out << change('材质', name, '已删除', [], name)
        else
          items = material_diff(a, b)
          out << change('材质', name, '已修改', items, name) unless items.empty?
        end
      end

      items = dicts_diff(old['model_dicts'] || {}, cur['model_dicts'] || {})
      out << change('视觉设置', '整个模型', '已修改', items, 'model') unless items.empty?

      oe = by(old['entities'], 'key')
      ce = by(cur['entities'], 'key')
      (oe.keys | ce.keys).each do |k|
        a = oe[k]
        b = ce[k]
        label = (a || b)['label']
        if a.nil?
          out << change('灯光/组件', label, '快照之后新增', [], nil)
        elsif b.nil?
          out << change('灯光/组件', label, '已删除或找不到', [], k)
        else
          items = dicts_diff(a['dicts'], b['dicts'])
          out << change('灯光/组件', label, '已修改', items, k) unless items.empty?
        end
      end
      out
    end

    def change(scope, name, kind, items, restore_key)
      { 'scope' => scope, 'name' => name, 'kind' => kind,
        'items' => items, 'restore_key' => restore_key }
    end

    def by(list, key)
      h = {}
      (list || []).each { |r| h[r[key]] = r }
      h
    end

    # 每条变化为 [字段, 快照里的值, 现在的值]
    def material_diff(a, b)
      items = []
      items << ['颜色', color_s(a['color']), color_s(b['color'])] if a['color'] != b['color']
      items << ['不透明度', a['alpha'], b['alpha']] if a['alpha'] != b['alpha']
      ta = a['texture']
      tb = b['texture']
      if ta.nil? != tb.nil?
        items << ['贴图', ta ? ta['file'] : '无', tb ? tb['file'] : '无']
      elsif ta
        items << ['贴图图像', ta['file'], "#{tb['file']}（图像已被替换）"] if ta['md5'] != tb['md5']
        if ta['width'] != tb['width'] || ta['height'] != tb['height']
          items << ['贴图尺寸', size_s(ta), size_s(tb)]
        end
      end
      items.concat(dicts_diff(a['dicts'] || {}, b['dicts'] || {}))
    end

    def dicts_diff(a, b)
      items = []
      (a.keys | b.keys).each do |dn|
        da = a[dn] || {}
        db = b[dn] || {}
        (da.keys | db.keys).each do |k|
          next if da[k] == db[k]
          items.concat(value_diff("#{dn}.#{k}", da[k], db[k]))
        end
      end
      items
    end

    # Enscape 材质 XML 和视觉设置 JSON 拆到字段级，其他值整体比
    def value_diff(field, va, vb)
      label = short(field)
      # 一边没有、一边是整段 Enscape 材质：不贴 XML 原文
      if va.nil? && enscape_xml?(vb)
        return [[label, '（无）', '新增了 Enscape 材质设置']]
      elsif vb.nil? && enscape_xml?(va)
        return [[label, '有 Enscape 材质设置', '（已移除）']]
      end
      if va.is_a?(String) && vb.is_a?(String)
        if va.include?('<SketchupMaterial') && vb.include?('<SketchupMaterial')
          return field_map_diff(label, xml_fields(va), xml_fields(vb))
        end
        ja = parse_json(va)
        jb = parse_json(vb)
        return field_map_diff(label, flatten(ja), flatten(jb)) if ja && jb
      end
      [[label, brief(va), brief(vb)]]
    end

    def enscape_xml?(v)
      v.is_a?(String) && v.include?('<SketchupMaterial')
    end

    def field_map_diff(prefix, ha, hb)
      (ha.keys | hb.keys).reject { |k| ha[k] == hb[k] }.map do |k|
        ["#{prefix} · #{k}", brief(ha[k]), brief(hb[k])]
      end
    end

    def xml_fields(xml)
      h = {}
      body = xml.gsub(TEX_RE) do
        slot = Regexp.last_match(1)
        inner = Regexp.last_match(2)
        inner.scan(TAG_RE) { |k, v| h["#{slot}.#{k}"] = v }
        ''
      end
      body.scan(TAG_RE) { |k, v| h[k] = v }
      h
    end

    def parse_json(s)
      t = s.strip
      return nil unless t.start_with?('{', '[')
      JSON.parse(t, allow_nan: true)
    rescue JSON::ParserError
      nil
    end

    def flatten(obj, prefix = '', out = {})
      case obj
      when Hash
        obj.each { |k, v| flatten(v, prefix.empty? ? k.to_s : "#{prefix}.#{k}", out) }
      when Array
        obj.each_with_index { |v, i| flatten(v, "#{prefix}[#{i}]", out) }
      else
        out[prefix.sub(/\ASettings\./, '').sub(/\.Value\z/, '')] = obj
      end
      out
    end

    def short(field)
      field.sub('Enscape.Material.MaterialData', 'Enscape')
           .sub(/\AEnscape\.EmbeddedSettings\.[^.]*/, 'Enscape 设置')
    end

    def brief(v)
      return '（无）' if v.nil?
      s = v.is_a?(String) ? v : JSON.generate(v, allow_nan: true)
      s.length > 60 ? "#{s[0, 57]}…" : s
    end

    def color_s(c)
      c ? c.first(3).join(',') : '（无）'
    end

    def size_s(t)
      format('%.1f × %.1f', t['width'].to_f, t['height'].to_f)
    end

    # ---------------- 回滚 ----------------
    # 只处理 changes 里有 restore_key 的项；整个过程是一次可撤销操作

    def restore(model, snap_dir, snap, changes)
      mats = by(snap['materials'], 'name')
      ents = by(snap['entities'], 'key')
      done = []
      skipped = []
      model.start_operation('工装资产：回滚到快照', true)
      begin
        changes.each do |c|
          k = c['restore_key']
          next unless k
          case c['scope']
          when '材质'
            apply_material(model, snap_dir, mats[k])
            done << c
          when '视觉设置'
            apply_dicts(model, snap['model_dicts'] || {}, ENSCAPE)
            done << c
          else
            ent = find_entity(model, k)
            if ent
              apply_dicts(ent, ents[k]['dicts'], ENSCAPE)
              done << c
            else
              skipped << c
            end
          end
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      [done, skipped]
    end

    def apply_material(model, snap_dir, rec)
      m = model.materials[rec['name']] || model.materials.add(rec['name'])
      t = rec['texture']
      if t && t['copy']
        m.texture = File.join(snap_dir, t['copy'])
        m.texture.size = [t['width'], t['height']] if m.texture
      elsif t.nil? && m.texture
        m.texture = nil
      end
      # 带贴图的材质设颜色会被 SketchUp 当成「着色」，只有快照里本来就着过色才设
      deltas = rec['colorize_deltas']
      colorized = deltas.is_a?(Array) && deltas.any? { |x| x.to_f.abs > 1e-6 }
      if colorized && rec['colorize_type'] && m.respond_to?(:colorize_type=)
        m.colorize_type = rec['colorize_type']
      end
      m.color = Sketchup::Color.new(*rec['color']) if m.texture.nil? || colorized
      m.alpha = rec['alpha']
      apply_dicts(m, rec['dicts'] || {}, nil)
      m
    end

    # 让实体上的字典与快照完全一致。
    # 快照里没有的字典只删 Enscape 自己的，其他插件的不动。
    def apply_dicts(entity, want, prefix)
      have = entity.attribute_dictionaries
      if have
        have.map(&:name).each do |n|
          next if want.key?(n)
          next if prefix && !n.start_with?(prefix)
          next unless n.start_with?(ENSCAPE)
          have.delete(n)
        end
      end
      want.each do |dname, kv|
        kv.each do |k, v|
          val = load_value(v)
          next if val == :unsupported
          entity.set_attribute(dname, k, val)
        end
        d = entity.attribute_dictionary(dname)
        (d.keys - kv.keys).each { |k| d.delete_key(k) } if d
      end
    end

    def find_entity(model, key)
      kind, id = key.split(':', 2)
      return model.definitions[id] if kind == 'def'
      pid = id.to_i
      model.definitions.each do |d|
        d.instances.each { |i| return i if i.persistent_id == pid }
      end
      nil
    end
  end
end
