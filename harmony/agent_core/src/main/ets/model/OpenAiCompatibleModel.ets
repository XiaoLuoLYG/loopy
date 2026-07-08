import http from '@ohos.net.http';
import { ChatMessage, ConversationContext } from '../agent/ConversationContext';
import { buildLoopSystemPrompt, SkillSnapshot } from '../skill/SkillSnapshot';
import { agentError, agentInfo } from '../util/AgentLog';
import { LocalModel } from './LocalModel';
import { LlmProvider } from './LlmProvider';

interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature: number;
}

interface ChatChoice {
  message?: ChatMessage;
}

interface ChatResponse {
  choices?: ChatChoice[];
}

export class OpenAiCompatibleModel implements LocalModel {
  private provider: LlmProvider;
  private skillSnapshot: SkillSnapshot | null;

  constructor(provider: LlmProvider, skillSnapshot?: SkillSnapshot) {
    this.provider = provider;
    this.skillSnapshot = skillSnapshot ?? null;
  }

  async complete(prompt: string, conversation?: ConversationContext): Promise<string> {
    if (!this.provider.isConfigured()) {
      throw new Error('LLM provider is not configured.');
    }

    agentInfo('LLM: request started, promptLen=%{public}s', `${prompt.length}`);

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(this.provider.chatCompletionsUrl(), {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${this.provider.apiKey}`,
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json'
        },
        extraData: JSON.stringify(this.buildRequest(prompt, conversation)),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 60000
      });

      const statusCode = response.responseCode;
      const body = `${response.result ?? ''}`;
      if (statusCode < 200 || statusCode >= 300) {
        throw new Error(`LLM request failed with HTTP ${statusCode}: ${body}`);
      }

      const content = this.parseContent(body);
      agentInfo('LLM: request succeeded, responseLen=%{public}s, content=%{public}s',
        `${content.length}`, content);
      return content;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      agentError('LLM: request failed: %{public}s', message);
      throw new Error(`LLM request failed: ${message}`);
    } finally {
      httpRequest.destroy();
    }
  }

  private buildRequest(prompt: string, conversation?: ConversationContext): ChatRequest {
    const messages: ChatMessage[] = [
      {
        role: 'system',
        content: buildLoopSystemPrompt(this.skillSnapshot)
      }
    ];

    if (conversation !== undefined) {
      const history = conversation.toChatMessages();
      for (const turn of history) {
        messages.push(turn);
      }
    }

    messages.push({
      role: 'user',
      content: prompt
    });

    return {
      model: this.provider.model,
      messages,
      temperature: 0.2
    };
  }

  private parseContent(body: string): string {
    const json = JSON.parse(body) as ChatResponse;
    const choices = json.choices;
    if (choices === undefined || choices.length === 0) {
      throw new Error('No choices returned.');
    }

    const message = choices[0].message;
    if (message === undefined || message.content === undefined) {
      throw new Error('No message content returned.');
    }
    return message.content.trim();
  }
}
