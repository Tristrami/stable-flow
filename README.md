1. 使用 ​​Paymaster​​ 让用户直接用稳定币支付 Gas
1. ​自动化稳定币操作​: 抵押率低于最低值时，自动抵入
1. 账户自动操作：账户冻结、社交恢复
1. 跨链稳定币管理​: 在 AA 钱包中集成 ​​跨链消息协议，用户单笔交易即可完成：
   1. 在链 A 销毁稳定币
   1. 在链 B 铸造稳定币
1. 使用 Beacon 模式部署 `SFAccount`
   1. 代理合约：`BeaconProxy`
   1. Beacon 合约：`UpgradeableBeacon`