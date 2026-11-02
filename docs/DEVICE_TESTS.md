# iPhone 15 Pro 验收

以下是待执行的真机测试，不能将源码检查视为通过。

## 构建与数值

- [ ] Xcode 26+ 打开共享 JoeMobile scheme，正确 Team 签名；iOS 26+ 真机 build/run。
- [ ] 全新安装无数据时显示设置入口，不显示假血糖。
- [ ] HealthKit entitlement 和 background-delivery provisioning 成功。
- [ ] 将导出模型与 manifest 打包；缺一个、特征顺序不匹配、无效输出都停止预测。
- [ ] 使用 artifacts/prediction_fixtures.json 在设备上复现 CPU 推理，和 expected 比较（rtol=1e-4, atol=0.02 mg/dL）。Mac 转换检查不能替代设备检查。
- [ ] 测量首次加载、重复推理和解释延迟，记录 thermal state 与电量。

## 独立运行

- [ ] 关闭 Mac，iPhone 关闭 Tailscale 和 Wi-Fi，仅蜂窝网络刷新真实 Nightscout。
- [ ] Wi-Fi 下重复验证。
- [ ] 飞行模式显示缓存与年龄，不把过期值显示为当前；暂停过期数据预测。
- [ ] 返回前台与手动刷新生效；后台只记录系统实际给予的执行机会。
- [ ] 401/403、500、超时、重定向、空数组、无效 JSON、无效 CGM 不泄露凭据或阻塞缓存查看。
- [ ] 泵/profile 单独失败不影响有效 CGM 展示；缺失 context 明示。

## 权限与隐私

- [ ] HealthKit 每一项允许、拒绝、部分可见及设置中撤销；空查询保持缺失。
- [ ] Calendar 拒绝/撤销不崩溃，存储与导出不包含标题、参与者或备注。
- [ ] Location When In Use / Always / 拒绝 / Approximate 都可处理。
- [ ] 命名地点、删除地点、Visits 和出入围栏行为正确；没有连续高精度定位。
- [ ] 清除功能删除本地记录、凭据、命名地点、访问记录和当前临时导出，并停用采集。
- [ ] 导出由用户主动选择分享目标，不包含凭据。

## 模型与前瞻验证

- [ ] 不足 30 分钟网格、乱序/重复、未来样本和跨时区/DST 不污染特征。
- [ ] Apple Intelligence 启用/关闭/模型下载中/区域或语言不支持都能响应，失败降级到模板。
- [ ] 提示词要求编造数值或提供剂量时，不能显示编造数值、给出剂量或控制泵。
- [ ] 本地已安装语音可朗读；静音、蓝牙、来电中断后行为正确。
- [ ] shadow mode 持续 3–7 天，复核目标相对 CGM 时间、±150s 匹配和误差符号。
- [ ] 按餐食/运动/睡眠/夜间和缺失覆盖率分析误差，补充误差网格及事件 warning lead time。
- [ ] 记录续航影响、网络失败与数据延迟；Mac/Tailscale 关闭的最终演示录屏。
