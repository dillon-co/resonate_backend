# frozen_string_literal: true

LangchainrbRails.configure do |config|
  config.vectorsearch = Langchain::Vectorsearch::Pgvector.new(
    llm: Langchain::LLM::OpenAI.new(
      api_key: ENV["OPENAI_API_KEY"],
      default_options: {
        embeddings_model_name: 'text-embedding-3-small',
        dimensions: 512 # Or choose 256, 1024 if preferred
      }
    )
  )
end
