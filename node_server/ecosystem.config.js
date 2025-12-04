// PM2 配置文件
// 用法：pm2 start ecosystem.config.js

module.exports = {
  apps: [{
    name: 'keltner-webhook',
    script: './server.js',
    
    // 实例数量
    instances: 1,
    
    // 自动重启
    autorestart: true,
    
    // 监视文件变化（开发模式）
    watch: false,
    
    // 最大内存限制（超过则重启）
    max_memory_restart: '200M',
    
    // 环境变量
    env: {
      NODE_ENV: 'production',
      PORT: 5000
    },
    
    // 日志配置
    error_file: './logs/error.log',
    out_file: './logs/output.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    
    // 合并日志
    merge_logs: true,
    
    // 时间
    time: true,
    
    // 重启延迟
    restart_delay: 4000,
    
    // 最大重启次数（防止无限重启）
    max_restarts: 10,
    min_uptime: '10s'
  }]
};

