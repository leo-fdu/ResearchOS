import json
from test_brainstorm import BrainstormTests as Fixture
from ros.brainstorm import RULES, TOOL

class SharedReadingGuidanceTests(Fixture):
    def test_members_receive_actionable_reading_guidance(self):
        room = self.room()
        for phase in ('discussion', 'reply', 'verification'):
            prompt = self.brain.prompt(room['id'], room['members'][0], phase, 1)
            self.assertIn('Before substantive discussion, reply or verification', prompt)
            self.assertIn('read_source for public URLs', prompt)
            self.assertIn('a title, shared note', prompt)
            self.assertIn('do not reread unchanged sources', prompt)
            context = json.loads(prompt.split('\n\n', 1)[1])
            self.assertIn('shared_sources', context)
        self.assertIn('read_source reads', TOOL['description'])

del Fixture
