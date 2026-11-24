// File-input driver for arrow-tools/tsv2arrow.cpp.
//
// tsv2arrow's process_one_input_file() ignores its FILE* and always getline()s from stdin, so the
// input file named last on the command line is opened as stdin and tsv2arrow's own main() (renamed
// tsv2arrow_main at compile time) runs with the remaining arguments.
//
//   tsv2arrow [tsv2arrow options...] <input>
//       the input is the TSV/CSV body; the schema comes from -S on the command line.
//   tsv2arrow --schema-from-input [tsv2arrow options...] <input>
//       the input's FIRST line is passed as `-S <line>` (the schema-definition parser), the rest
//       of the input is the TSV/CSV body.
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern int tsv2arrow_main(int argc, char *argv[]);

int main(int argc, char *argv[])
{
	bool schema_from_input = false;
	std::vector<char *> args;

	if (argc < 2) {
		fprintf(stderr, "usage: %s [--schema-from-input] [tsv2arrow options] <input>\n", argv[0]);
		return 1;
	}
	if (!freopen(argv[argc - 1], "rb", stdin)) {
		perror(argv[argc - 1]);
		return 1;
	}
	args.push_back(argv[0]);
	for (int i = 1; i < argc - 1; i++) {
		if (strcmp(argv[i], "--schema-from-input") == 0)
			schema_from_input = true;
		else
			args.push_back(argv[i]);
	}
	static std::string schema;
	if (schema_from_input) {
		char *line = NULL;
		size_t sz = 0;
		ssize_t n = getline(&line, &sz, stdin);
		if (n <= 0)
			return 1;
		schema.assign(line, n);
		free(line);
		while (!schema.empty() && (schema.back() == '\n' || schema.back() == '\r'))
			schema.pop_back();
		args.push_back((char *)"-S");
		args.push_back(schema.data());
	}
	args.push_back(NULL);
	return tsv2arrow_main((int)args.size() - 1, args.data());
}
