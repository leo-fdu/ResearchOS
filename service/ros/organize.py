from dataclasses import asdict
import argparse
import json
from papermind.pdf_ops import organize
if __name__=='__main__':
    parser=argparse.ArgumentParser(description='Organize newest papers until an already organized PDF is reached.')
    parser.add_argument('--full',action='store_true',help='Check the entire PDF library without an early stop')
    args=parser.parse_args()
    print('ORGANIZE_RESULT: '+json.dumps(asdict(organize(stop_at_organized=not args.full)),ensure_ascii=False),flush=True)
