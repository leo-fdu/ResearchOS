// Only this tool is exposed in Research OS Pi processes. Credentials stay in Pi.
export default function (pi: any) {
  pi.registerTool({
    name: 'research_workbench', label: 'Research workbench',
    description: 'Access all Research OS resources, search literature, share sources, write private scripts, publish immutable artifacts and execute bounded verification. Use resources to discover records and registered directories. Use read with record id or PDF page; list/read_file with paths. write_file uses personal relative path. publish_file snapshots a private file. share_source requires title/url/note/reading. run requires a personal script path, optional args and seconds. sources lists shared evidence; read_source reads a public source URL by shared id; read accesses Research OS records; read_file accesses shared paths. Read relevant evidence before relying on it and acknowledge only the actual reading level.',
    parameters: {
      type: 'object', properties: {
        action: { type: 'string', enum: ['resources','search','read','view_page','list','read_file','write_file','publish_file','share_source','sources','acknowledge','read_source','scholarly_search','run'] },
        source: { type: 'string', enum: ['all','pubmed','arxiv','biorxiv'] },
        id: { type: 'string' }, query: { type: 'string' }, path: { type: 'string' }, text: { type: 'string' },
        title: { type: 'string' }, url: { type: 'string' }, note: { type: 'string' },
        reading: { type: 'string', enum: ['found','abstract','full_text'] },
        offset: { type: 'integer' }, page: { type: 'integer' }, seconds: { type: 'integer' }, args: { type: 'array', items: { type: 'string' } }
      }, required: ['action'], additionalProperties: false
    },
    async execute(_id: string, params: any, signal: AbortSignal) {
      const response = await fetch(process.env.RESEARCHOS_WORKBENCH_URL!, {
        method: 'POST', headers: {'Content-Type': 'application/json', 'X-Brainstorm-Token': process.env.RESEARCHOS_WORKBENCH_TOKEN!},
        body: JSON.stringify(params), signal
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || 'Workbench request failed');
      if (result.image_url) {
        const match = result.image_url.match(/^data:([^;]+);base64,(.*)$/s);
        if (!match) throw new Error('Invalid image response');
        return {content: [{type: 'text', text: result.citation || ''}, {type: 'image', data: match[2], mimeType: match[1]}], details: {}};
      }
      return { content: [{type: 'text', text: JSON.stringify(result)}], details: {} };
    }
  });
}
