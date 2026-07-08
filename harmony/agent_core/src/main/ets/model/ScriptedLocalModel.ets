import { ConversationContext } from '../agent/ConversationContext';
import { SkillSnapshot } from '../skill/SkillSnapshot';
import { agentInfo } from '../util/AgentLog';
import { LocalModel } from './LocalModel';

export class ScriptedLocalModel implements LocalModel {
  private skillSnapshot: SkillSnapshot | null;

  constructor(skillSnapshot?: SkillSnapshot) {
    this.skillSnapshot = skillSnapshot ?? null;
  }

  async complete(prompt: string, _conversation?: ConversationContext): Promise<string> {
    if (prompt.toLowerCase().includes('observation:')) {
      return this.completeAfterObservation(prompt);
    }

    const task = this.extractTask(prompt);
    const lower = task.toLowerCase();

    if (this.isSimpleChat(lower)) {
      agentInfo('ScriptedModel: simple chat, Final without skill');
      return `Thought: This is general chat; no skill is needed.\nFinal: I received your message: ${task}`;
    }

    const suggested = this.skillSnapshot?.suggestForTask(task) ?? null;
    if (suggested !== null) {
      agentInfo('ScriptedModel: matched skill %{public}s, Action: read[]', suggested.name);
      return `Thought: The ${suggested.name} skill matches this task; I should load it first.\nAction: read[${suggested.name}]`;
    }

    if (lower.includes('time') || lower.includes('date')) {
      agentInfo('ScriptedModel: ReAct action time[]');
      return 'Thought: I should inspect the device clock.\nAction: time[]';
    }
    if (this.wantsUi(lower)) {
      agentInfo('ScriptedModel: ReAct action ui[]');
      return `Thought: The user wants a visual UI on screen.\nAction: ui[${task}]`;
    }

    agentInfo('ScriptedModel: ReAct action note[]');
    return `Thought: I should preserve the user's request as local context.\nAction: note[${task}]`;
  }

  private completeAfterObservation(prompt: string): string {
    if (prompt.includes('# Skill:')) {
      const skillName = this.parseLoadedSkillName(prompt);
      if (this.skillRequiresTime(prompt)) {
        if (!this.hasTimeObservation(prompt)) {
          agentInfo('ScriptedModel: skill %{public}s requires time, Action: time[]', skillName);
          return 'Thought: The loaded skill requires the current time.\nAction: time[]';
        }
        const timeValue = this.extractLastTimeObservation(prompt);
        agentInfo('ScriptedModel: after time observation, Final');
        return `Thought: I have the current time from the device.\nFinal: 现在是 ${timeValue}。`;
      }

      const task = this.extractTask(prompt);
      agentInfo('ScriptedModel: after read skill %{public}s, Final', skillName);
      return `Thought: I loaded the ${skillName} skill and will follow its instructions.\n` +
        `Final: I applied the ${skillName} skill for: ${task}. Offline demo mode cannot call ` +
        'external services — follow the skill body above for format and boundaries, and configure ' +
        'providers or tools for live data when needed.';
    }

    if (prompt.toLowerCase().includes('rendered on-screen ui')) {
      return 'Thought: The UI is on screen; I can summarize.\n' +
        'Final: I rendered an on-screen card for your request. Check the panel above the chat.';
    }

    return 'Thought: I have enough local context to answer.\n' +
      'Final: I ran the local ReAct loop and used the available device tool result.';
  }

  private parseLoadedSkillName(prompt: string): string {
    const marker = '# Skill:';
    const start = prompt.lastIndexOf(marker);
    if (start === -1) {
      return 'unknown';
    }
    const rest = prompt.substring(start + marker.length).trim();
    const lineEnd = rest.indexOf('\n');
    return lineEnd >= 0 ? rest.substring(0, lineEnd).trim() : rest.trim();
  }

  private skillRequiresTime(prompt: string): boolean {
    return prompt.includes('Action: time[]')
      || prompt.includes('查询当前时间')
      || prompt.includes('查询现在几点');
  }

  private hasTimeObservation(prompt: string): boolean {
    const timeActionIndex = prompt.lastIndexOf('Action: time[]');
    if (timeActionIndex < 0) {
      return false;
    }
    const afterTimeAction = prompt.substring(timeActionIndex);
    const obsIndex = afterTimeAction.indexOf('Observation:');
    if (obsIndex < 0) {
      return false;
    }
    const obsContent = afterTimeAction.substring(obsIndex + 'Observation:'.length).trim();
    return obsContent.length > 0 && !obsContent.startsWith('# Skill:');
  }

  private extractLastTimeObservation(prompt: string): string {
    const timeActionIndex = prompt.lastIndexOf('Action: time[]');
    if (timeActionIndex < 0) {
      return 'unknown time';
    }
    const afterTimeAction = prompt.substring(timeActionIndex);
    const obsIndex = afterTimeAction.indexOf('Observation:');
    if (obsIndex < 0) {
      return 'unknown time';
    }
    let obsContent = afterTimeAction.substring(obsIndex + 'Observation:'.length);
    const nextThought = obsContent.indexOf('\nThought:');
    if (nextThought >= 0) {
      obsContent = obsContent.substring(0, nextThought);
    }
    const firstLine = obsContent.trim().split('\n')[0]?.trim() ?? '';
    return firstLine.length > 0 ? firstLine : 'unknown time';
  }

  private isSimpleChat(lowerTask: string): boolean {
    return lowerTask === 'hi'
      || lowerTask === 'hello'
      || lowerTask.startsWith('hello ')
      || lowerTask.startsWith('hi ');
  }

  private wantsUi(task: string): boolean {
    return task.includes('card')
      || task.includes(' ui')
      || task.startsWith('ui ')
      || task.includes('show ')
      || task.includes('display')
      || task.includes('visual')
      || task.includes('welcome')
      || task.includes('dashboard')
      || task.includes('form');
  }

  private extractTask(prompt: string): string {
    const marker = 'User task:';
    const start = prompt.indexOf(marker);
    if (start === -1) {
      return 'No task found';
    }

    let task = prompt.substring(start + marker.length).trim();
    const nextSection = task.indexOf('\n\n');
    if (nextSection >= 0) {
      task = task.substring(0, nextSection).trim();
    }
    return task.replace(/\[/g, '(').replace(/\]/g, ')');
  }
}
