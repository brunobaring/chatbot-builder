# Chatbot Builder

Site para criar e interagir com um chatbot conversacional personalizado.

## Pré-requisitos

- [Node.js](https://nodejs.org) v18 ou superior
- Uma chave de API da Anthropic

## Instalação

```bash
# 1. Instale as dependências
npm install

# 2. Configure a chave da API
cp .env.example .env
# Edite o arquivo .env e coloque sua ANTHROPIC_API_KEY

# 3. Inicie o servidor
npm start
```

Acesse: http://localhost:3000

## O que configura

| Atributo | Opções |
|---|---|
| Nome da Empresa | Texto livre |
| Telefone de Contato | Texto livre |
| Tom | Amigável / Formal / Informal / Profissional |
| Humor | Leve / Bem-humorado / Sério |
