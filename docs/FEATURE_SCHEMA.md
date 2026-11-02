# joe.features.v1

时间为 UTC；界面才转换成本地时间。用最新 CGM 的 source timestamp 为预测原点。feature timestamp 为其所在五分钟桶；预测 30/60 分钟的目标同样相对于 source timestamp。刷新时记录的生成时间与 CGM 时间不同。

模型输入为 19 个值，后接同序的 19 个 missingness flag（缺失为 1）。缺失值占位为 0，只能与 flag 一起使用。顺序以 `FeatureRow.names` / `features.INPUT_NAMES` 为准。

| 索引 | 字段 | 定义 / 单位 |
|---|---|---|
| 0 | glucose | 最新有效 CGM，mg/dL |
| 1 | delta_5m | 当前减五分钟前，mg/dL |
| 2 | slope_15m | 当前减十五分钟前再除以 15，mg/dL/min |
| 3–4 | mean_30m / std_30m | 七个五分钟点的均值与总体标准差 |
| 5 | basal_rate | 尚在 duration 内的最近 Temp Basal absolute；U/h；不从 profile 猜测实际输注 |
| 6 | bolus_30m | 过去 30 分钟可见 insulin 事件之和；无记录时缺失 |
| 7 | estimated_iob | 当前版本始终缺失，等待验证的作用模型 |
| 8 | carbs_2h | 过去两小时可见碳水事件之和，g；无记录时缺失 |
| 9 | estimated_cob | 当前版本始终缺失 |
| 10 | steps_30m | HealthKit 30 分钟统计，使用系统来源合并 |
| 11 | heart_rate | 最近 15 分钟内可见心率，bpm |
| 12 | workout_active | 有可见近两小时 workout 时，判断是否在截止点前 5 分钟内结束；无记录为缺失，属于近似特征 |
| 13 | sleep_hours | 最近 36 小时内最后一段睡眠 episode 的小时数；重叠区间先合并，间隔超过三小时分段 |
| 14 | place | unknown=0, home=1, school=2, work=3, gym=4, restaurant=5, other=6 |
| 15 | calendar | other=0, class=1, meeting=2, meal=3, travel=4, medical=5, exercise=6；无事件为缺失 |
| 16–17 | hour_sin / hour_cos | UTC 日内秒数除以 86400 后乘 2π 的 sin / cos |
| 18 | weekday | UTC 星期，周一=0，周日=6 |

核心 CGM 网格仅允许从过去最多 150 秒 carry-forward，七个点任一缺失就拒绝预测。最新样本超过设置阈值（默认 15 分钟）拒绝预测。context 必须不晚于 CGM source timestamp，且最多 15 分钟前。

部分治疗记录、同步失败和上传延迟可能影响事件覆盖。当前离线数据集按 source time 重放，无法完整重建历史 Nightscout 上传时间或 HealthKit 数据到达时间；离线结果须视为回顾性分析，真实运行表现以 shadow-mode 日志为准。不得将此重放称为已验证的实时可用性。

Profile 原始响应本地保存供后续研究核查，但尚未解析 profile schedule、DIA 或单位，因此不推断基础率、IOB/COB。Nightscout 必须提供 mg/dL 的 sgv；当前没有 mmol/L 输入转换。

后续实际值：在目标 CGM 时间 ±150 秒内选最近有效读数。整个匹配窗口经过后才评估；误差 = 预测 − 实测。未找到实际值保持空，不插值、不填零。

模型输出两个有序 mg/dL 值：30 分钟、60 分钟。验证集 P90 残差绝对值为固定不确定性摘要，不能视为经过校准的个体预测区间。低血糖概率当前为 nil。
