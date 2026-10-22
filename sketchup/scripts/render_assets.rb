# 组件资产标准图：对当前模型的顶层组件逐个隔离，按 正/侧/顶/轴测 出白底图 + 信息表。
# 所有隐藏/显示改动在一个操作里，结束时 abort 全部撤销；相机与渲染设置恢复原状；不保存模型。
# 用法（Ruby 控制台，SketchUp 2024）:
#   load File.join(Dir.home, 'Desktop', 'render_assets.rb')
#   AssetRender.run(20)
# 输出: 桌面/asset_render/<模型名>/  PNG + assets.csv
require 'csv'
require 'fileutils'

module AssetRender
  VIEWS = {
    'front' => [Geom::Vector3d.new(0, -1, 0), Z_AXIS],
    'side'  => [Geom::Vector3d.new(1, 0, 0),  Z_AXIS],
    'top'   => [Geom::Vector3d.new(0, 0, 1),  Y_AXIS],
    'iso'   => [Geom::Vector3d.new(1, -1, 1), Z_AXIS]
  }.freeze
  STYLE = { 'BackgroundColor' => Sketchup::Color.new(255, 255, 255),
            'DrawGround' => false, 'DrawHorizon' => false, 'DrawSky' => false }.freeze

  def self.run(limit = 20)
    model = Sketchup.active_model
    view  = model.active_view
    name  = File.basename(model.path, '.skp')
    out   = File.join(Dir.home, 'Desktop', 'asset_render', name)
    FileUtils.mkdir_p(out)

    targets = model.entities.grep(Sketchup::ComponentInstance)
                   .group_by(&:definition)
                   .sort_by { |d, _| -d.count_used_instances }
                   .first(limit)
    puts "顶层组件定义 #{model.entities.grep(Sketchup::ComponentInstance).map(&:definition).uniq.size} 个，本次出图 #{targets.size} 个 → #{out}"

    old_cam   = view.camera
    saved_cam = Sketchup::Camera.new(old_cam.eye, old_cam.target, old_cam.up, old_cam.perspective?, old_cam.fov)
    saved_cam.height = old_cam.height unless old_cam.perspective?
    ro        = model.rendering_options
    saved_ro  = STYLE.keys.to_h { |k| [k, ro[k]] }
    rows = []

    model.start_operation('AssetRender', true)
    begin
      STYLE.each { |k, v| ro[k] = v }
      model.entities.each { |e| e.hidden = true if e.respond_to?(:hidden=) }
      targets.each_with_index do |(defn, insts), i|
        inst = insts.first
        inst.hidden = false
        inst.layer.visible = true if inst.layer.respond_to?(:visible=)
        bb = inst.bounds
        r  = [bb.diagonal / 2.0, 1.mm].max
        base = format('%03d_%s', i + 1, defn.name.gsub(/[\\\/:*?"<>|#\s]/, '_'))
        VIEWS.each do |vname, (dir, up)|
          d   = dir.normalize
          eye = bb.center.offset(d, r * 4)
          cam = Sketchup::Camera.new(eye, bb.center, up, false)
          cam.height = r * 2.2
          view.camera = cam
          view.write_image(filename: File.join(out, "#{base}_#{vname}.png"),
                           width: 800, height: 800, antialias: true)
        end
        db = defn.bounds
        mats = defn.entities.grep(Sketchup::Face).flat_map { |f| [f.material, f.back_material] }
                   .compact.map(&:display_name).uniq
        mats.unshift(inst.material.display_name) if inst.material
        rows << [base, defn.name, defn.count_used_instances,
                 db.width.to_mm.round, db.depth.to_mm.round, db.height.to_mm.round,
                 mats.uniq.first(5).join(' / '), model.path]
        inst.hidden = true
        puts "[#{i + 1}/#{targets.size}] #{defn.name}"
      end
    ensure
      model.abort_operation
      saved_ro.each { |k, v| ro[k] = v }
      view.camera = saved_cam
    end

    File.open(File.join(out, 'assets.csv'), 'w:UTF-8') do |f|
      f.write("﻿" + %w[image_prefix name instances width_mm depth_mm height_mm materials source].to_csv)
      rows.each { |r| f.write(r.to_csv) }
    end
    puts "完成：#{rows.size} 个组件 × #{VIEWS.size} 视角 → #{out}"
  end
end
