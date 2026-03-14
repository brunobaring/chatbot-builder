module.exports = {
  apps: [
    {
      name: 'chatbot-prod',
      script: 'server.js',
      cwd: '/var/www/chatbot-prod',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
    },
    {
      name: 'chatbot-dev',
      script: 'server.js',
      cwd: '/var/www/chatbot-dev',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '256M',
    },
  ],
};
