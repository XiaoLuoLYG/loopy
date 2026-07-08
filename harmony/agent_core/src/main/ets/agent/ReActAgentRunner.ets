import { AgentEvent, AgentEventKind } from './AgentEvent';
import { ConversationContext } from './ConversationContext';
import { ToolRegistry } from './ToolRegistry';
import { LocalModel } from '../model/LocalModel';
import { agentError, agentInfo } from '../util/AgentLog';
import { buildReActFormatRules, buildSkillsSection, SkillSnapshot } from '../skill/SkillSnapshot';

export type AgentListener = (event: AgentEvent) => void;
export type UiRenderHandler = (description: string) => Promise<string[]>;

const UI_TOOL_NAME = 'ui';
const READ_TOOL_NAME = 'read';

class ToolCall {
  name: string;
  input: string;

  constructor(name: string, input: string) {
    this.name = name;
    this.input = input;
  }
}

export class ReActAgentRunner {
  private model: LocalModel;
  private tools: ToolRegistry;
  private skillSnapshot: SkillSnapshot | null;
  private skillsInSystemPrompt: boolean;
  private maxSteps: number;
  private uiHandler: UiRenderHandler | null;

  constructor(
    model: LocalModel,
    tools: ToolRegistry,
    maxSteps: number,
    uiHandler?: UiRenderHandler,
    skillSnapshot?: SkillSnapshot,
    skillsInSystemPrompt: boolean = false
  ) {
    this.model = model;
    this.tools = tools;
    this.skillSnapshot = skillSnapshot ?? null;
    this.skillsInSystemPrompt = skillsInSystemPrompt;
    this.maxSteps = maxSteps;
    this.uiHandler = uiHandler ?? null;
  }

  async run(task: string, listener: AgentListener, conversation?: ConversationContext): Promise<void> {
    agentInfo('Agent: run started, task=%{public}s', task);

    const scratchpad: string[] = [];
    for (let step = 0; step < this.maxSteps; step++) {
      agentInfo('Agent: ReAct step %{public}s', `${step + 1}`);
      let response: string;
      try {
        response = await this.model.complete(
          this.buildReActPrompt(task, scratchpad, conversation),
          conversation
        );
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        agentError('Agent: model error in ReAct step %{public}s: %{public}s', `${step + 1}`, message);
        listener(new AgentEvent(AgentEventKind.ERROR, message));
        return;
      }

      this.emitResponse(response, listener);

      const finalAnswer = this.readLineValue(response, 'Final:');
      if (finalAnswer !== null) {
        agentInfo('Agent: ReAct final answer at step %{public}s', `${step + 1}`);
        listener(new AgentEvent(AgentEventKind.FINAL, finalAnswer));
        return;
      }

      const call = this.parseAction(response);
      if (call === null) {
        agentError('Agent: no Action or Final at step %{public}s, response=%{public}s', `${step + 1}`, response);
        listener(new AgentEvent(AgentEventKind.ERROR, 'Model did not return an Action or Final answer.'));
        return;
      }

      agentInfo('Agent: action %{public}s(%{public}s)', call.name, call.input);
      listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));

      let observation: string;
      if (call.name === UI_TOOL_NAME) {
        observation = await this.runUiTool(call.input, listener);
      } else {
        observation = this.tools.run(call.name, call.input);
        if (call.name === READ_TOOL_NAME) {
          this.emitSkillRead(call.input, observation, listener);
        }
      }

      scratchpad.push(response);
      scratchpad.push(`Observation: ${observation}`);
      agentInfo('Agent: observation %{public}s', observation);
      listener(new AgentEvent(AgentEventKind.OBSERVATION, observation));
    }

    agentError('Agent: stopped after %{public}s steps without final answer', `${this.maxSteps}`);
    listener(new AgentEvent(AgentEventKind.ERROR, `Stopped after ${this.maxSteps} steps without a final answer.`));
  }

  private emitSkillRead(input: string, observation: string, listener: AgentListener): void {
    if (this.skillSnapshot === null || !observation.startsWith('# Skill:')) {
      return;
    }
    const skill = this.skillSnapshot.findByName(input.trim());
    if (skill !== null) {
      agentInfo('Agent: read skill %{public}s', skill.name);
      listener(new AgentEvent(AgentEventKind.SKILL, skill.name));
    }
  }

  private async runUiTool(description: string, listener: AgentListener): Promise<string> {
    if (this.uiHandler === null) {
      return 'UI rendering is not available in this session.';
    }

    const prompt = description.trim().length > 0 ? description : 'Simple information card';
    try {
      const lines = await this.uiHandler(prompt);
      if (lines.length === 0) {
        return 'UI tool returned no protocol data.';
      }
      listener(new AgentEvent(AgentEventKind.UI, lines.join('\n')));
      return `Rendered on-screen UI (${lines.length} protocol lines) for: ${prompt}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      return `UI render failed: ${message}`;
    }
  }

  private buildReActPrompt(
    task: string,
    scratchpad: string[],
    conversation: ConversationContext | undefined
  ): string {
    let prompt = 'You are Loop, a HarmonyOS ReAct agent with tools.\n';
    prompt += buildReActFormatRules();
    prompt += '\nUse the ui tool when the user wants something shown on screen (card, form, dashboard, visual summary).\n';
    if (!this.skillsInSystemPrompt) {
      prompt += 'Use Action: read[skill_name] to load skill instructions before following them.\n\n';
    } else {
      prompt += '\n';
    }

    if (conversation !== undefined && !conversation.isEmpty()) {
      prompt += conversation.formatPriorConversation();
    }

    if (!this.skillsInSystemPrompt) {
      const skillsSection = buildSkillsSection(this.skillSnapshot);
      if (skillsSection.length > 0) {
        prompt += `${skillsSection}\n\n`;
      }
    }

    prompt += 'Tools:\n';
    prompt += this.tools.describeTools();
    prompt += '\nUser task:\n';
    prompt += task;
    prompt += '\n\n';

    for (const item of scratchpad) {
      prompt += `${item}\n`;
    }
    return prompt;
  }

  private emitResponse(response: string, listener: AgentListener): void {
    const thought = this.readLineValue(response, 'Thought:');
    if (thought !== null) {
      listener(new AgentEvent(AgentEventKind.THOUGHT, thought));
    }
  }

  private readLineValue(text: string, prefix: string): string | null {
    const lines = text.split(/\r?\n/);
    for (const line of lines) {
      const normalized = this.normalizeProtocolLine(line);
      if (normalized.startsWith(prefix)) {
        return normalized.substring(prefix.length).trim();
      }
    }
    return null;
  }

  private normalizeProtocolLine(line: string): string {
    let normalized = line.trim();
    normalized = normalized.replace(/^\*\*/, '').replace(/\*\*$/, '');
    normalized = normalized.replace(/^[-*]\s+/, '');
    return normalized.trim();
  }

  private parseAction(response: string): ToolCall | null {
    const action = this.readLineValue(response, 'Action:');
    if (action === null) {
      return null;
    }

    const open = action.indexOf('[');
    const close = action.lastIndexOf(']');
    if (open <= 0 || close < open) {
      return null;
    }

    const name = action.substring(0, open).trim();
    const input = action.substring(open + 1, close).trim();
    return new ToolCall(name, input);
  }
}
