import sys
import logging
from .parser import build_parser

logger = logging.getLogger(__name__)


def main() -> int:
    parser = build_parser()

    try:
        if len(sys.argv) == 1:
            parser.print_help()
            return 0

        args = parser.parse_args()

        if args.command == "search":
            from .search import cmd_search

            cmd_search(args)
        elif args.command == "summarize":
            import asyncio
            from .summarize import cmd_summarize

            asyncio.run(cmd_summarize(args))
        elif args.command == "config":
            from .config import cmd_config

            cmd_config(args, parser)
        elif args.command == "cache":
            from .cache import cmd_cache

            cmd_cache(args, parser)
        elif args.command == "filings":
            import asyncio
            from .filings import cmd_filings

            asyncio.run(cmd_filings(args))
        elif args.command == "filing":
            import asyncio
            from .filings import cmd_filing

            asyncio.run(cmd_filing(args))
        elif args.command == "sector":
            from .sector import cmd_sector

            cmd_sector(args)
        else:
            parser.print_help()
        return 0
    except KeyboardInterrupt:
        print("\n中断しました。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
